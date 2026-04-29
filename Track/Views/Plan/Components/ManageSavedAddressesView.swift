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
    @State private var visibilityUpdates: Set<Int> = []

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
            List {
                Section {
                    HStack(spacing: 0) {
                        statBlock(value: "\(places.count)", label: "Saved")
                        Divider().padding(.horizontal, 8)
                        statBlock(value: "\(visiblePlacesCount)", label: "On Map")
                        Divider().padding(.horizontal, 8)
                        statBlock(value: "\(customCount)", label: "Custom")
                    }
                    .padding(.vertical, 6)
                }

                if let errorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AppTheme.Colors.alertRed)
                            Text(errorMessage)
                                .font(.subheadline)
                            Spacer()
                            Button { self.errorMessage = nil } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button(action: startNewAddress) {
                        Label("Add Place via Search", systemImage: "magnifyingglass")
                            .foregroundColor(AppTheme.Colors.accent)
                    }
                    Button(action: startNewAddressFromMap) {
                        Label("Pick from Map", systemImage: "map.fill")
                            .foregroundColor(AppTheme.Colors.accent)
                    }
                }

                if isLoading && places.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading places...")
                                .padding(.vertical, 12)
                            Spacer()
                        }
                    }
                } else if places.isEmpty {
                    Section {
                        VStack(alignment: .center, spacing: 12) {
                            Image(systemName: "mappin.slash.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(AppTheme.Colors.accent, AppTheme.Colors.accent.opacity(0.2))
                            Text("No saved places yet")
                                .font(.headline)
                            Text("Add home, work, school, or any custom stop once and reuse it everywhere.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                } else {
                    Section(header: Text("Saved Locations")) {
                        ForEach(sortedPlaces) { place in
                            savedAddressRow(place)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Places")
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
                    .fontWeight(.semibold)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { startNewAddress() } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("Add saved address")
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private func savedAddressRow(_ place: SavedLocation) -> some View {
        let isUpdating = place.enginePlaceID.map { visibilityUpdates.contains($0) } ?? false

        return HStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: place.iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.accent)

                    if place.visibleOnMap {
                        Circle()
                            .fill(AppTheme.Colors.successGreen)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                            .offset(x: 14, y: 14)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(place.name)
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(place.resolvedCategory.label)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(UIColor.tertiarySystemFill))
                            .clipShape(Capsule())
                    }

                    Text(place.address.isEmpty ? coordinateText(place) : place.address)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { edit(place) }

            Spacer(minLength: 0)

            Button {
                Task { await toggleVisibility(place) }
            } label: {
                ZStack {
                    Image(systemName: place.visibleOnMap ? "eye.fill" : "eye.slash")
                        .font(.system(size: 18))
                        .foregroundColor(place.visibleOnMap ? AppTheme.Colors.accent : AppTheme.Colors.textTertiary)
                        .opacity(isUpdating ? 0 : 1)
                    if isUpdating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .accessibilityLabel(place.visibleOnMap ? "Hide on map" : "Show on map")
        }
        .padding(.vertical, 4)
        .foregroundColor(.primary)
    }

    private func coordinateText(_ place: SavedLocation) -> String {
        String(format: "%.4f, %.4f", place.latitude, place.longitude)
    }

    private func savedAddressEditor(_ currentDraft: SavedAddressDraft) -> some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(AppTheme.Colors.accent)
                                .frame(width: 60, height: 60)
                            
                            Image(systemName: draft?.icon ?? currentDraft.icon)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text((draft?.label ?? currentDraft.label).isEmpty ? "New saved place" : (draft?.label ?? currentDraft.label))
                                .font(.headline)
                                .lineLimit(1)
                            Text((draft?.address ?? currentDraft.address).isEmpty ? "Choose a location with Apple search or the map." : (draft?.address ?? currentDraft.address))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text("Details")) {
                    TextField("Name (e.g., Home, Work, Gym)", text: Binding(
                        get: { draft?.label ?? currentDraft.label },
                        set: { draft?.label = $0 }
                    ))
                    
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
                }

                Section(header: Text("Location")) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search Apple Maps", text: $searchQuery)
                            .onChange(of: searchQuery) { _, value in
                                appleSearch.updateQuery(value)
                            }
                            
                        if isResolvingSearch || appleSearch.isSearching {
                            ProgressView().scaleEffect(0.8)
                        } else if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                                appleSearch.cancel()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !appleSearch.completions.isEmpty {
                        ForEach(appleSearch.completions.prefix(5)) { completion in
                            Button {
                                Task { await selectAppleCompletion(completion) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: completion.iconName)
                                        .foregroundColor(AppTheme.Colors.accent)
                                        
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(completion.title)
                                            .foregroundColor(.primary)
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    Button {
                        showMapPicker = true
                    } label: {
                        Label("Choose with Map", systemImage: "map.fill")
                            .foregroundColor(AppTheme.Colors.accent)
                    }

                    if (draft ?? currentDraft).hasCoordinate {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(AppTheme.Colors.successGreen)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text((draft ?? currentDraft).address.isEmpty ? "Location selected" : (draft ?? currentDraft).address)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(String(format: "%.4f, %.4f", (draft ?? currentDraft).latitude, (draft ?? currentDraft).longitude))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("Icon")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(PlanViewModel.customPlaceIcons, id: \.icon) { option in
                            let isSelected = draft?.icon == option.icon
                            Button { draft?.icon = option.icon } label: {
                                Image(systemName: option.icon)
                                    .font(.system(size: 20))
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .frame(height: 44)
                                    .frame(maxWidth: .infinity)
                                    .background(isSelected ? AppTheme.Colors.accent : Color(UIColor.secondarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Toggle("Show as a map pin", isOn: Binding(
                        get: { draft?.visibleOnMap ?? true },
                        set: { draft?.visibleOnMap = $0 }
                    ))
                }

                if currentDraft.placeID != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await deleteDraft() }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Place")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
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
                    .fontWeight(.bold)
                    .disabled(isSaving || draft?.hasCoordinate != true)
                }
            }
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
        if let placeID = place.enginePlaceID {
            visibilityUpdates.insert(placeID)
        }
        defer {
            if let placeID = place.enginePlaceID {
                visibilityUpdates.remove(placeID)
            }
        }
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
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.ultraThinMaterial))
            }

            Spacer()

            Text("Choose Location")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
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
                .fill(Color.secondary.opacity(0.35))
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
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(resolvedName.isEmpty ? "Selected pin" : resolvedName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(resolvedAddress.isEmpty ? String(format: "%.4f, %.4f", centerCoordinate.latitude, centerCoordinate.longitude) : resolvedAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                onConfirm(centerCoordinate, resolvedName, resolvedAddress)
            } label: {
                Label("Use This Location", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.Gradients.accent)
                    )
            }
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

#Preview {
    ManageSavedAddressesView()
        .preferredColorScheme(.dark)
}
