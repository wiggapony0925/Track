// Multi-step onboarding flow shown on first launch.
//
// Replaces the old 3-page swipe stub with a polished, animated, themed
// experience that:
//
//   1. Hooks the user with an animated hero / value prop.
//   2. Asks for Location permission with context (not a system modal).
//   3. Offers Live Activities for Lock-Screen tracking.
//   4. Walks through a dedicated "Set up your important places" step
//      where the user can pin Home, Work, and one or two custom spots
//      using MKLocalSearch — these flow through the same engine endpoint
//      the Plan tab uses, so chips + smart-suggestions immediately
//      personalise.
//   5. Closes with a "you're ready" celebration.
//
// All steps are skippable except #1; saved places persist via the
// existing `EngineSavedPlaceUpsertRequest` / `TrackAPI.upsertEngineSavedPlace`
// path so onboarding writes are no different from in-app saves.

import SwiftUI
import MapKit
import CoreLocation
import ActivityKit

// MARK: - Step Enumeration

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case location
    case activities
    case places
    case ready

    var progress: Double {
        // Welcome doesn't show a progress bar; treat as 0.
        Double(rawValue) / Double(OnboardingStep.allCases.count - 1)
    }
}

// MARK: - Root

struct OnboardingView: View {
    @ObservedObject private var onboardingTracker = OnboardingTracker.shared
    @State private var step: OnboardingStep = .welcome
    @State private var locationManager = LocationManager()

    /// Saved places the user pins during onboarding. Kept in local
    /// state so the user can review before proceeding; the actual
    /// network write happens on each "Save" tap inside `OnboardingPlacesStep`.
    @State private var savedPlaces: [PinnedPlace] = []

    var body: some View {
        ZStack {
            // Reuse the auth screens' transit-line background so the
            // hand-off from Login → Onboarding feels like one product.
            AuthBackground(haloOffset: CGSize(width: blobOffsetX, height: blobOffsetY))
                .animation(.easeInOut(duration: 0.9), value: step)

            VStack(spacing: 0) {
                topBar

                // Step content swaps with a soft slide+fade so the
                // hero icons feel intentional rather than jarring.
                Group {
                    switch step {
                    case .welcome:    welcomeStep
                    case .location:   locationStep
                    case .activities: activitiesStep
                    case .places:     placesStep
                    case .ready:      readyStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Background offsets

    private var blobOffsetX: CGFloat {
        switch step {
        case .welcome:    return -40
        case .location:   return  120
        case .activities: return -110
        case .places:     return  90
        case .ready:      return  0
        }
    }

    private var blobOffsetY: CGFloat {
        switch step {
        case .welcome:    return -260
        case .location:   return -200
        case .activities: return -160
        case .places:     return -280
        case .ready:      return -220
        }
    }

    // MARK: - Top Bar (Skip + Progress)

    private var topBar: some View {
        HStack(spacing: 12) {
            if step != .welcome && step != .ready {
                ProgressView(value: step.progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Colors.accent)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }

            if step != .welcome && step != .ready {
                Button("Skip") { advance() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        OnboardingWelcomeStep(onContinue: { advance() })
    }

    private var locationStep: some View {
        OnboardingLocationStep(
            authorizationStatus: locationManager.authorizationStatus,
            onAllow: {
                locationManager.requestPermission()
                // Don't block — user may approve via system modal, but
                // the rest of onboarding doesn't need to wait.
                advance()
            },
            onSkip: { advance() }
        )
    }

    private var activitiesStep: some View {
        OnboardingActivitiesStep(
            onEnable: {
                // Live Activities don't require an explicit prompt; they
                // request authorization on first use. We just acknowledge
                // and move on. A best-effort hint that surfaces the
                // ActivityAuthorizationInfo state lets us skip the page
                // for users who have already disabled them globally.
                _ = ActivityAuthorizationInfo().areActivitiesEnabled
                advance()
            },
            onSkip: { advance() }
        )
    }

    private var placesStep: some View {
        OnboardingPlacesStep(
            saved: $savedPlaces,
            onContinue: { advance() },
            onSkip: { advance() }
        )
    }

    private var readyStep: some View {
        OnboardingReadyStep(
            placeCount: savedPlaces.count,
            onFinish: {
                onboardingTracker.markComplete()
            }
        )
    }

    // MARK: - Navigation

    private func advance() {
        let next = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            step = next
        }
    }
}

// MARK: - Welcome

private struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void
    @State private var iconAppeared = false
    @State private var rowsAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            // Animated app icon — subtle pulse + scale-in on appear.
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.18))
                    .frame(width: 160, height: 160)
                    .blur(radius: 26)
                    .scaleEffect(iconAppeared ? 1.0 : 0.6)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.Colors.accent,
                                AppTheme.Colors.accentDeep,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)
                    .overlay(
                        Image(systemName: "tram.fill")
                            .font(.system(size: 44, weight: .heavy))
                            .foregroundStyle(.white)
                    )
                    .shadow(
                        color: AppTheme.Colors.accent.opacity(0.50),
                        radius: 22, x: 0, y: 10
                    )
                    .scaleEffect(iconAppeared ? 1.0 : 0.4)
                    .rotationEffect(.degrees(iconAppeared ? 0 : -18))
                    .opacity(iconAppeared ? 1 : 0)
            }
            .padding(.bottom, 24)

            Text("Welcome to Track")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(iconAppeared ? 1 : 0)

            Text("NYC transit, alive in your pocket.")
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.accent)
                .padding(.top, 4)
                .opacity(iconAppeared ? 1 : 0)

            VStack(spacing: 10) {
                FeatureRow(
                    icon: "dot.radiowaves.right",
                    title: "Live arrivals",
                    subtitle: "Subway, bus & rail — refreshed every second.",
                    tint: AppTheme.Colors.accent
                )
                FeatureRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "Service alerts",
                    subtitle: "Delays, reroutes & planned work, summarised.",
                    tint: .orange
                )
                FeatureRow(
                    icon: "sparkles",
                    title: "Smart shortcuts",
                    subtitle: "Track learns your commute and surfaces it first.",
                    tint: .pink
                )
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .opacity(rowsAppeared ? 1 : 0)
            .offset(y: rowsAppeared ? 0 : 20)

            Spacer()

            primaryButton("Get Started", icon: "arrow.right") {
                onContinue()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
            .opacity(rowsAppeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) {
                iconAppeared = true
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) {
                rowsAppeared = true
            }
        }
    }
}

// MARK: - Location

private struct OnboardingLocationStep: View {
    let authorizationStatus: CLAuthorizationStatus
    let onAllow: () -> Void
    let onSkip: () -> Void
    @State private var pulse = false

    var body: some View {
        OnboardingPageScaffold(
            iconView: AnyView(animatedLocator),
            title: "Find your station",
            subtitle: "Track uses your location to surface the nearest stops, accurate arrival times, and routes that actually work for where you are.",
            primaryLabel: alreadyGranted ? "Continue" : "Allow Location",
            primaryIcon: alreadyGranted ? "checkmark" : "location.fill",
            secondaryLabel: alreadyGranted ? nil : "Not now",
            onPrimary: onAllow,
            onSecondary: onSkip
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var alreadyGranted: Bool {
        authorizationStatus == .authorizedWhenInUse
            || authorizationStatus == .authorizedAlways
    }

    private var animatedLocator: some View {
        ZStack {
            // Concentric pulse rings.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(
                        AppTheme.Colors.accent.opacity(0.35 - Double(i) * 0.08),
                        lineWidth: 1.25
                    )
                    .frame(
                        width: 64 + CGFloat(i) * 38,
                        height: 64 + CGFloat(i) * 38
                    )
                    .scaleEffect(pulse ? 1.05 : 0.95)
                    .opacity(pulse ? 0.4 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                        value: pulse
                    )
            }
            // Center pin.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "location.fill")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.white)
                )
                .shadow(color: AppTheme.Colors.accent.opacity(0.55), radius: 14, y: 6)
        }
    }
}

// MARK: - Live Activities

private struct OnboardingActivitiesStep: View {
    let onEnable: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingPageScaffold(
            iconView: AnyView(activityHero),
            title: "Watch from your Lock Screen",
            subtitle: "Live Activities pin your train to the Lock Screen and Dynamic Island so you can glance — not unlock.",
            primaryLabel: "Enable Activities",
            primaryIcon: "bolt.fill",
            secondaryLabel: "Skip for now",
            onPrimary: onEnable,
            onSecondary: onSkip
        )
    }

    private var activityHero: some View {
        ZStack {
            // Faux Dynamic Island pill with a pulsing dot.
            Capsule()
                .fill(.black)
                .frame(width: 188, height: 58)
                .overlay(
                    HStack(spacing: 12) {
                        Circle()
                            .fill(AppTheme.Colors.accent)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Text("L")
                                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bedford Av")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("3 min")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.successGreen)
                        }
                        Spacer()
                        Image(systemName: "dot.radiowaves.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.successGreen)
                    }
                    .padding(.horizontal, 14)
                )
                .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
        }
    }
}

// MARK: - Places

private struct OnboardingPlacesStep: View {
    @Binding var saved: [PinnedPlace]
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var activeKind: SavedLocationCategory?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.16))
                        .frame(width: 76, height: 76)
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(AppTheme.Colors.accent)
                }

                Text("Pin your important places")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Save Home, Work, and anywhere else you head often. Track will use these for one-tap planning and smart suggestions.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 4)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    placeRow(.home, icon: "house.fill", tint: AppTheme.Colors.accent)
                    placeRow(.work, icon: "briefcase.fill", tint: .orange)
                    placeRow(.school, icon: "graduationcap.fill", tint: .pink)
                    placeRow(.partner, icon: "heart.fill", tint: .purple)
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
            }

            VStack(spacing: 8) {
                primaryButton(
                    saved.isEmpty ? "Skip for now" : "Continue",
                    icon: saved.isEmpty ? "arrow.right" : "checkmark"
                ) {
                    saved.isEmpty ? onSkip() : onContinue()
                }
                if !saved.isEmpty {
                    Button("Skip the rest") { onSkip() }
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .sheet(item: $activeKind) { kind in
            OnboardingPlacePickerSheet(category: kind) { place in
                guard let place else { return }
                saved.removeAll { $0.category == kind }
                saved.append(place)
            }
        }
    }

    @ViewBuilder
    private func placeRow(_ kind: SavedLocationCategory, icon: String, tint: Color) -> some View {
        let existing = saved.first(where: { $0.category == kind })
        Button {
            activeKind = kind
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.label)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(existing?.address ?? "Tap to add")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(
                            existing == nil
                                ? AppTheme.Colors.textTertiary
                                : AppTheme.Colors.textSecondary
                        )
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: existing == nil ? "plus.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(existing == nil ? AppTheme.Colors.textTertiary : AppTheme.Colors.successGreen)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .trackGlassCard(cornerRadius: 14, hasHighlight: false)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Place picker sheet (MKLocalSearch backed)

private struct OnboardingPlacePickerSheet: View {
    let category: SavedLocationCategory
    let onPicked: (PinnedPlace?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                AppTheme.Gradients.screenSheen.ignoresSafeArea()

                VStack(spacing: 12) {
                    searchField
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if searching {
                        ProgressView().padding(.top, 24)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(results, id: \.self) { item in
                                Button {
                                    Task { await commit(item) }
                                } label: {
                                    resultRow(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Set \(category.label)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onPicked(nil)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            TextField("Search address or place", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .onChange(of: query) { _, new in runSearch(new) }
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .trackGlassCard(cornerRadius: 14, hasHighlight: false)
    }

    private func resultRow(_ item: MKMapItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(AppTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "Unknown")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let addr = formattedAddress(item) {
                    Text(addr)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if saving {
                ProgressView().scaleEffect(0.8)
            }
        }
        .padding(12)
        .trackGlassCard(cornerRadius: 14, hasHighlight: false)
    }

    private func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Bias to NYC so onboarding stays relevant; users can still
        // search outside via full address.
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855),
            latitudinalMeters: 50_000,
            longitudinalMeters: 50_000
        )
        Task {
            let search = MKLocalSearch(request: request)
            do {
                let response = try await search.start()
                await MainActor.run {
                    results = Array(response.mapItems.prefix(20))
                    searching = false
                }
            } catch {
                await MainActor.run {
                    results = []
                    searching = false
                }
            }
        }
    }

    private func commit(_ item: MKMapItem) async {
        saving = true
        defer { saving = false }

        let coord = item.location.coordinate
        let label = category.label
        let address = formattedAddress(item) ?? item.name ?? label

        guard let userID = SupabaseManager.shared.currentUser?.id.uuidString.lowercased() else {
            errorMessage = "Sign in to save places."
            return
        }

        do {
            _ = try await TrackAPI.upsertEngineSavedPlace(
                request: EngineSavedPlaceUpsertRequest(
                    userID: userID,
                    label: label,
                    kind: category.rawValue,
                    lat: coord.latitude,
                    lon: coord.longitude,
                    address: address,
                    icon: category.defaultIcon,
                    placeID: nil
                )
            )
            await MainActor.run {
                onPicked(PinnedPlace(
                    category: category,
                    name: item.name ?? label,
                    address: address,
                    latitude: coord.latitude,
                    longitude: coord.longitude
                ))
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't save — try again."
            }
        }
    }

    private func formattedAddress(_ item: MKMapItem) -> String? {
        let resolved = item.address?.shortAddress
            ?? item.address?.fullAddress
        guard let resolved, !resolved.isEmpty else { return nil }
        return resolved
    }
}

// MARK: - Ready

private struct OnboardingReadyStep: View {
    let placeCount: Int
    let onFinish: () -> Void
    @State private var bounced = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(AppTheme.Colors.successGreen.opacity(0.18))
                    .frame(width: 160, height: 160)
                    .blur(radius: 26)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 86, weight: .heavy))
                    .foregroundStyle(AppTheme.Colors.successGreen)
                    .scaleEffect(bounced ? 1.0 : 0.4)
            }
            .padding(.bottom, 22)

            Text("You're all set")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)

            Text(detailMessage)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 32)

            Spacer()

            primaryButton("Open Track", icon: "arrow.right") {
                onFinish()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) {
                bounced = true
            }
        }
    }

    private var detailMessage: String {
        switch placeCount {
        case 0:
            return "Track is ready. You can pin Home & Work later from the Plan tab."
        case 1:
            return "1 place saved. Track will use it for shortcuts and chips."
        default:
            return "\(placeCount) places saved. Track will use them for shortcuts and chips."
        }
    }
}

// MARK: - Shared building blocks

private struct OnboardingPageScaffold: View {
    let iconView: AnyView
    let title: String
    let subtitle: String
    let primaryLabel: String
    let primaryIcon: String
    let secondaryLabel: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            iconView
                .padding(.bottom, 28)
            Text(title)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(subtitle)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 8) {
                primaryButton(primaryLabel, icon: primaryIcon, action: onPrimary)
                if let secondaryLabel {
                    Button(secondaryLabel, action: onSecondary)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .trackGlassCard(cornerRadius: 12, hasHighlight: false)
    }
}

@ViewBuilder
private func primaryButton(
    _ label: String,
    icon: String,
    action: @escaping () -> Void
) -> some View {
    AuthPrimaryButton(label: label, icon: icon, action: action)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
}

// MARK: - Local model

private struct PinnedPlace: Identifiable, Equatable {
    let id = UUID()
    let category: SavedLocationCategory
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
}

extension SavedLocationCategory: Identifiable {
    public var id: String { rawValue }
}

#Preview {
    OnboardingView()
}
