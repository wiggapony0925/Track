// Plan tab — immersive trip planner with rich SwiftUI components.
// Every button, gesture, and interaction is wired to live ViewModel
// logic. Nothing is decorative-only.

import SwiftUI
import SwiftData
import CoreLocation
import MapLibre

struct PlanView: View {
    @Environment(\.modelContext) private var modelContext
    let locationManager: LocationManager
    var homeViewModel: HomeViewModel
    @Binding var selectedTab: AppTab
    @Binding var cameraPosition: TrackCameraPosition
    @Binding var showStations: Bool
    @Binding var currentMapCenter: CLLocationCoordinate2D?
    @Binding var currentMapDistance: Double?
    @State private var viewModel = PlanViewModel()
    @State private var animatePulse = false
    @State private var appeared = false
    @State private var headerParallax: CGFloat = 0
    @State private var randomHeadline: String = "Where to?"
    @State private var cardShakeOffset: CGFloat = 0
    @State private var showSameLocationToast = false

    private static let headlines: [String] = [
        "Where to?",
        "Let's roll 🚇",
        "Next stop?",
        "Let's bounce 🏀",
        "On the move",
        "Going places?",
        "What's the move?",
        "Choo choo 🚂",
        "Take me there",
        "Ready to go?",
        "Touch grass 🌱",
        "Time to dip",
        "Run it back",
        "Tap in 🚏",
        "Slide through",
        "Catch a wave 🌊",
        "Your chariot awaits",
        "Where we droppin'?",
        "Fast travel IRL",
        "Subway surfer 🏄",
        "Mission accepted",
        "Let's get lost",
        "Plot the route",
        "Pick a vibe",
        "Main character era ✨",
        "Adventure awaits",
        "No traffic today 😌",
        "Ride or walk?",
        "You up? (for a trip)",
        "Swipe right 💜"
    ]

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Late night ride?"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppTheme.Gradients.screen.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroHeader
                        mainContent
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .ignoresSafeArea(edges: .top)
                .refreshable {
                    await viewModel.refreshPlannerData()
                }

                if viewModel.destination != nil {
                    goButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Floating pill tab bar — bottom-trailing, same as Home tab
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        FloatingTabPill(selectedTab: $selectedTab)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.configure(
                    modelContext: modelContext,
                    locationManager: locationManager
                )
                withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                    appeared = true
                }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    animatePulse = true
                }
            }
            .onChange(of: viewModel.sameLocationMessage) { _, newValue in
                guard newValue != nil else { return }
                checkSameLocation()
            }
            .task {
                // Pre-fetch commute plans in background after a short delay
                // so the UI loads first and critical requests take priority.
                try? await Task.sleep(for: .seconds(3))
                await viewModel.prefetchCommutePlans()
            }
            .sheet(isPresented: $viewModel.showDestinationSearch) {
                DestinationSearchView(viewModel: viewModel, isOrigin: false)
            }
            .sheet(isPresented: $viewModel.showOriginSearch) {
                DestinationSearchView(viewModel: viewModel, isOrigin: true)
            }
            .sheet(isPresented: $viewModel.showTimePicker) {
                DepartureTimePickerSheet(viewModel: viewModel)
            }
            .fullScreenCover(isPresented: $viewModel.showResults) {
                TripResultsView(viewModel: viewModel)
            }
            .fullScreenCover(isPresented: $viewModel.showMapPicker) {
                MapLocationPickerView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showAddPlaceSheet) {
                AddPlaceSheet(viewModel: viewModel)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .top) {
                if !viewModel.showResults, let message = viewModel.errorMessage {
                    toastBanner(message)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Hero Header
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var heroHeader: some View {
        VStack(spacing: 0) {
            // ── Map banner with polylines + purple fade ──
            ZStack(alignment: .bottom) {
                // Real interactive MapLibre map — same instance data as
                // the Home tab. Camera + polylines stay perfectly in sync.
                MapLibreTrackMapView(
                    cameraPosition: $cameraPosition,
                    viewModel: homeViewModel,
                    locationManager: locationManager,
                    showStations: $showStations,
                    currentMapCenter: $currentMapCenter,
                    currentMapDistance: $currentMapDistance
                )
                .allowsHitTesting(true)

                // Purple fade overlay with subtle noise texture
                LinearGradient(
                    stops: [
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.15), location: 0),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.45), location: 0.30),
                        .init(color: AppTheme.Colors.accentDeep.opacity(0.80), location: 0.65),
                        .init(color: AppTheme.Colors.background, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                // Headline text on the map
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(greeting)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.80))
                            Text(randomHeadline)
                                .font(.system(size: 32, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .id(randomHeadline)
                                .transition(.opacity)
                                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 46)
                }
                .opacity(appeared ? 1 : 0)
            }
            .frame(height: 310)

            // ── Route input card overlapping map ──
            ZStack(alignment: .bottom) {
                routeInputCard
                    .offset(x: cardShakeOffset)

                // Same-location toast
                if showSameLocationToast, let msg = viewModel.sameLocationMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "figure.stand")
                            .font(.system(size: 14, weight: .bold))
                        Text(msg)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(AppTheme.Colors.textOnColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.accent)
                            .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 12, y: 4)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .offset(y: 28)
                    .zIndex(2)
                }
            }
            .padding(.top, -36)
            .zIndex(1)

            // ── Departure controls ──
            DepartureTimeControl(
                departureOption: $viewModel.departureOption,
                onPickerTap: { viewModel.showTimePicker = true },
                onStep: { viewModel.stepTime(forward: $0) },
                onClear: { viewModel.clearDepartureOption() }
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .onAppear {
            randomHeadline = Self.headlines.randomElement() ?? "Where to?"
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Route Input Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var routeInputCard: some View {
        HStack(spacing: 0) {
            // ── Colored dots + dashed connector ──
            VStack(spacing: 0) {
                // Origin dot — accent with glow ring
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.12))
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(AppTheme.Colors.accent)
                        .frame(width: 11, height: 11)
                }

                // Dashed connector
                DashedConnector()
                    .stroke(
                        AppTheme.Colors.textTertiary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5])
                    )
                    .frame(width: 2, height: 32)

                // Destination dot — red with glow ring
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.alertRed.opacity(0.12))
                        .frame(width: 22, height: 22)
                    Image(systemName: "mappin")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AppTheme.Colors.alertRed)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)

            // ── From / To fields ──
            VStack(spacing: 0) {
                // Origin
                Button {
                    viewModel.showOriginSearch = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionHeader(title: "From", size: 10, tracking: 1.0, color: AppTheme.Colors.accent.opacity(0.65))
                            Text(viewModel.origin.displayName)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)

                // Divider
                Rectangle()
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.10))
                    .frame(height: 1)

                // Destination
                Button {
                    viewModel.showDestinationSearch = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionHeader(title: "To", size: 10, tracking: 1.0, color: AppTheme.Colors.alertRed.opacity(0.55))
                            Text(viewModel.destination?.displayName ?? "Where to?")
                                .font(.system(size: 16, weight: viewModel.destination != nil ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(
                                    viewModel.destination != nil
                                        ? AppTheme.Colors.textPrimary
                                        : AppTheme.Colors.textTertiary
                                )
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)

                        if viewModel.destination != nil {
                            Button {
                                withAnimation(AppTheme.Animation.snappy) { viewModel.destination = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(AppTheme.Colors.textTertiary.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 4)

            // ── Swap button ──
            Button {
                let didSwap = withAnimation(AppTheme.Animation.snappy) {
                    viewModel.swapOriginDestination()
                }
                if didSwap, viewModel.showResults {
                    Task { await viewModel.planTrip() }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Circle()
                        .strokeBorder(AppTheme.Colors.accent.opacity(0.15), lineWidth: 1)
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
            .buttonStyle(PlanCardButtonStyle())
            .padding(.trailing, 14)
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: AppTheme.Colors.glassHighlight.opacity(0.06), location: 0),
                                    .init(color: .clear, location: 0.4),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
        )
        .padding(.horizontal, 16)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Go Button (Floating)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var goButton: some View {
        Button {
            Task { await viewModel.planTrip() }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoading {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                        .rotationEffect(.degrees(45))
                }
                Text(viewModel.isLoading ? "Finding routes..." : "Search Routes")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                ZStack {
                    Capsule().fill(
                        LinearGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    Capsule().fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.15), location: 0),
                                .init(color: .clear, location: 0.45),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
                .shadow(color: AppTheme.Colors.accent.opacity(0.45), radius: 18, y: 6)
            )
        }
        .disabled(viewModel.isLoading)
        .buttonStyle(PlanCardButtonStyle())
        .padding(.horizontal, 32)
        .padding(.bottom, 100)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Main Content
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @State private var shimmerPhase: CGFloat = 0

    private var mainContent: some View {
        VStack(spacing: 28) {
            if viewModel.isPlanDataLoaded {
                quickAccessRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)).animation(.easeOut(duration: 0.35)))
                savedPlacesSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)).animation(.easeOut(duration: 0.35).delay(0.05)))
                savedRoutesSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)).animation(.easeOut(duration: 0.35).delay(0.10)))
                suggestionsCarousel
                    .transition(.opacity.combined(with: .move(edge: .bottom)).animation(.easeOut(duration: 0.35).delay(0.15)))
                recentTripsSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)).animation(.easeOut(duration: 0.35).delay(0.20)))
            } else {
                skeletonQuickAccessRow
                    .transition(.opacity)
                skeletonSavedPlacesSection
                    .transition(.opacity)
                skeletonSuggestionsSection
                    .transition(.opacity)
                skeletonRecentTripsSection
                    .transition(.opacity)
            }
            Spacer(minLength: viewModel.destination != nil ? 120 : 80)
        }
        .padding(.top, 24)
        .animation(.easeInOut(duration: 0.4), value: viewModel.isPlanDataLoaded)
        .onAppear {
            shimmerPhase = 1.0
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Quick Access Row (Horizontal Tiles)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var quickAccessRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quickChip(
                    icon: "location.fill", label: "My Location",
                    color: .blue
                ) {
                    viewModel.origin = .currentLocation
                    Task { await viewModel.refreshPlannerData() }
                }

                quickChip(
                    icon: "map.fill", label: "Pick on Map",
                    color: AppTheme.Colors.accentSecondary
                ) {
                    viewModel.isOriginForMapPicker = false
                    viewModel.showMapPicker = true
                }

                quickChip(
                    icon: "arrow.clockwise", label: "Refresh",
                    color: AppTheme.Colors.successGreen
                ) {
                    Task { await viewModel.refreshPlannerData() }
                }

                if let suggestion = viewModel.recommendations.first {
                    quickChip(
                        icon: "sparkles", label: "Best Guess",
                        color: .purple
                    ) {
                        viewModel.selectRecommendation(suggestion)
                        Task { await viewModel.planTrip() }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .opacity(appeared ? 1 : 0)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Same-Location Shake
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Checks whether the ViewModel flagged same-location, and fires
    /// the card shake + toast if so.
    private func checkSameLocation() {
        guard viewModel.sameLocationMessage != nil else { return }
        triggerShake()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            showSameLocationToast = true
        }
        // Auto-dismiss after 2.5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showSameLocationToast = false
            }
            // Clear the message so the next tap can fire again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                viewModel.sameLocationMessage = nil
            }
        }
    }

    /// Rapid left-right shake, then spring back to center.
    private func triggerShake() {
        let offsets: [(CGFloat, Double)] = [
            (-12, 0.0), (10, 0.06), (-8, 0.12),
            (6, 0.18), (-3, 0.24), (0, 0.30),
        ]
        for (x, delay) in offsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.3)) {
                    cardShakeOffset = x
                }
            }
        }
    }

    private func quickChip(
        icon: String, label: String, color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(color.opacity(0.12))
                            .overlay(
                                Circle()
                                    .strokeBorder(color.opacity(0.18), lineWidth: 0.8)
                            )
                    )

                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            .padding(.trailing, 14)
            .padding(.leading, 7)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: AppTheme.Colors.glassHighlight.opacity(0.08), location: 0),
                                        .init(color: .clear, location: 0.5),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: color.opacity(0.08), radius: 8, y: 3)
            )
        }
        .buttonStyle(PlanCardButtonStyle())
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Saved Places (Circle Icons)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var savedPlacesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Saved Places")
                Spacer()
                Button {
                    viewModel.beginCustomPlaceFlow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .black))
                        Text("Add")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppTheme.Colors.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(AppTheme.Colors.accent.opacity(0.10))
                            .overlay(
                                Capsule()
                                    .strokeBorder(AppTheme.Colors.accent.opacity(0.15), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    placeCircle(
                        icon: "house.fill", label: "Home",
                        color: AppTheme.Colors.accent,
                        location: viewModel.savedLocation(for: .home),
                        category: .home
                    )
                    placeCircle(
                        icon: "briefcase.fill", label: "Work",
                        color: AppTheme.Colors.warningYellow,
                        location: viewModel.savedLocation(for: .work),
                        category: .work
                    )
                    placeCircle(
                        icon: "graduationcap.fill", label: "School",
                        color: AppTheme.Colors.successGreen,
                        location: viewModel.savedLocation(for: .school),
                        category: .school
                    )
                    placeCircle(
                        icon: "heart.fill",
                        label: viewModel.savedLocation(for: .partner)?.name ?? "Partner",
                        color: AppTheme.Colors.alertRed,
                        location: viewModel.savedLocation(for: .partner),
                        category: .partner
                    )

                    ForEach(viewModel.customSavedLocations) { place in
                        placeCircle(
                            icon: place.iconName, label: place.name,
                            color: AppTheme.Colors.accentSecondary,
                            location: place, category: nil
                        )
                    }

                    // Add new circle
                    Button { viewModel.beginCustomPlaceFlow() } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(AppTheme.Colors.cardInset.opacity(0.5))
                                    .frame(width: 54, height: 54)
                                Circle()
                                    .strokeBorder(
                                        AppTheme.Colors.borderSubtle.opacity(0.40),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                                    )
                                    .frame(width: 54, height: 54)
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(AppTheme.Colors.textTertiary)
                            }
                            Text("Add")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppTheme.Colors.textTertiary)
                        }
                    }
                    .buttonStyle(PlanCardButtonStyle())
                }
                .padding(.horizontal, 20)
            }
        }
        .opacity(appeared ? 1 : 0)
    }

    private func placeCircle(
        icon: String, label: String, color: Color,
        location: SavedLocation?, category: SavedLocationCategory?
    ) -> some View {
        Button {
            if let loc = location {
                viewModel.selectDestination(.saved(loc))
                Task { await viewModel.planTrip() }
            } else if let cat = category {
                viewModel.beginSavedPlaceFlow(cat)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    // Outer glow ring for set places
                    if location != nil {
                        Circle()
                            .fill(color.opacity(0.06))
                            .frame(width: 62, height: 62)
                    }

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(location != nil ? 0.22 : 0.06),
                                    color.opacity(location != nil ? 0.08 : 0.02),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .overlay(
                            Circle().strokeBorder(
                                color.opacity(location != nil ? 0.35 : 0.12), lineWidth: 1.5
                            )
                        )
                        .shadow(
                            color: location != nil ? color.opacity(0.20) : .clear,
                            radius: 10, y: 4
                        )

                    // Glass shimmer overlay
                    if location != nil {
                        Circle()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.08), location: 0),
                                        .init(color: .clear, location: 0.45),
                                    ],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 54, height: 54)
                    }

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color.opacity(location != nil ? 1 : 0.35))
                }

                Text(location != nil ? label : "Set")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        location != nil ? AppTheme.Colors.textPrimary : AppTheme.Colors.textTertiary
                    )
                    .lineLimit(1)
                    .frame(width: 62)
            }
        }
        .buttonStyle(PlanCardButtonStyle())
        .contextMenu {
            if let loc = location {
                Button(role: .destructive) {
                    Task { await viewModel.deleteSavedLocation(loc) }
                } label: {
                    Label("Remove \(label)", systemImage: "trash")
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - My Routes (Saved Trip Templates)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private var savedRoutesSection: some View {
        if !viewModel.savedTripTemplates.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("My Routes")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.savedTripTemplates) { template in
                            savedRouteCard(template)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func savedRouteCard(_ template: PlannerSavedTripRecord) -> some View {
        Button {
            viewModel.planFromTemplate(template)
        } label: {
            HStack(spacing: 0) {
                // Colored accent bar — left edge
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.Colors.accentSecondary, AppTheme.Colors.accent],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 3.5)
                    .padding(.vertical, 10)
                    .padding(.leading, 4)

                HStack(spacing: 14) {
                    // Left — star circle with ring
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.accentSecondary.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Circle()
                            .strokeBorder(AppTheme.Colors.accentSecondary.opacity(0.20), lineWidth: 1)
                            .frame(width: 44, height: 44)
                        Image(systemName: "star.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.accentSecondary)
                    }

                    // Center — text
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(template.originLabel)
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                            Text(template.destinationLabel)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textTertiary)

                        if !template.preferredModes.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(template.preferredModes.prefix(3), id: \.self) { mode in
                                    Image(systemName: modeIconForTemplate(mode))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(AppTheme.Colors.accent.opacity(0.7))
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    // Right — Go arrow with glass ring
                    ZStack {
                        Circle()
                            .fill(AppTheme.Colors.accentSecondary.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Circle()
                            .strokeBorder(AppTheme.Colors.accentSecondary.opacity(0.30), lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.accentSecondary)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
            }
            .frame(width: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: AppTheme.Colors.accentSecondary.opacity(0.04), location: 0),
                                        .init(color: .clear, location: 0.5),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AppTheme.Colors.accentSecondary.opacity(0.08), lineWidth: 0.8)
                    )
                    .shadow(color: AppTheme.Colors.accentSecondary.opacity(0.08), radius: 12, y: 4)
            )
        }
        .buttonStyle(PlanCardButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                Task { await viewModel.deleteSavedTripTemplate(template) }
            } label: {
                Label("Delete Route", systemImage: "trash")
            }
        }
    }

    private func modeIconForTemplate(_ mode: String) -> String {
        switch mode {
        case "subway": return "tram.fill"
        case "bus":    return "bus.fill"
        case "lirr", "mnr": return "train.side.front.car"
        case "walk":   return "figure.walk"
        default:       return "map.fill"
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Suggestions Carousel
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private var suggestionsCarousel: some View {
        if !viewModel.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Suggested for You")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.recommendations) { rec in
                            suggestionTile(rec)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func suggestionTile(_ rec: PlannerRecommendation) -> some View {
        let accent = recColor(rec.source)

        return Button {
            viewModel.selectRecommendation(rec)
            Task { await viewModel.planTrip() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Icon + arrow row
                HStack {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.10))
                            .frame(width: 38, height: 38)
                        Image(systemName: recIcon(rec.source))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(accent)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent.opacity(0.4))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(rec.label)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)

                    Text(rec.reason)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }

                Text(rec.subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(width: 190, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.55))
            )
        }
        .buttonStyle(.plain)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Recent Trips
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var recentTripsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Recent Trips")
                Spacer()
                if !viewModel.savedTrips.isEmpty {
                    Text("\(viewModel.savedTrips.count)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.Colors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(AppTheme.Colors.accent.opacity(0.10))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(AppTheme.Colors.accent.opacity(0.15), lineWidth: 0.5)
                                )
                        )
                        .padding(.trailing, 20)
                }
            }

            if viewModel.savedTrips.isEmpty {
                emptyRecentState
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(Array(viewModel.savedTrips.prefix(5).enumerated()), id: \.element.id) { index, trip in
                        RecentTripCard(trip: trip) {
                            viewModel.origin = .custom(
                                name: trip.originName,
                                address: trip.originAddress,
                                lat: trip.originLat,
                                lon: trip.originLon
                            )
                            viewModel.destination = .custom(
                                name: trip.destinationName,
                                address: trip.destinationAddress,
                                lat: trip.destinationLat,
                                lon: trip.destinationLon
                            )
                            Task { await viewModel.planTrip() }
                        }
                        .padding(.horizontal, 16)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(
                            .spring(response: 0.42, dampingFraction: 0.82)
                                .delay(Double(index) * 0.04),
                            value: appeared
                        )
                    }
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Empty Recent State
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var emptyRecentState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.04))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(AppTheme.Colors.cardBackground)
                    .frame(width: 66, height: 66)
                    .overlay(
                        Circle().strokeBorder(AppTheme.Colors.accent.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.Colors.accent.opacity(0.10), radius: 12)
                Image(systemName: "tram.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppTheme.Colors.accent, AppTheme.Colors.accentSecondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("No recent trips")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("Search a destination to plan your first trip")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Toast Banner
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.Colors.alertRed)

            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Button { viewModel.dismissError() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textTertiary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AppTheme.Colors.cardInset))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AppTheme.Colors.alertRed.opacity(0.15), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Skeleton Loading States
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func shimmerGradient(phase: CGFloat) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.04), location: max(0, phase - 0.3)),
                .init(color: .white.opacity(0.12), location: phase),
                .init(color: .white.opacity(0.04), location: min(1, phase + 0.3)),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var skeletonQuickAccessRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(AppTheme.Colors.cardBackground.opacity(0.5))
                        .overlay(
                            Capsule()
                                .fill(shimmerGradient(phase: shimmerPhase))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.10), lineWidth: 0.5)
                        )
                        .frame(width: 130, height: 42)
                }
            }
            .padding(.horizontal, 20)
        }
        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: shimmerPhase)
    }

    private var skeletonSavedPlacesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section title placeholder
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.3))
                    .frame(width: 3, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 4).fill(shimmerGradient(phase: shimmerPhase)))
                    .frame(width: 100, height: 12)
                Spacer()
            }
            .padding(.leading, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(spacing: 8) {
                            Circle()
                                .fill(AppTheme.Colors.cardBackground.opacity(0.35))
                                .overlay(
                                    Circle()
                                        .fill(shimmerGradient(phase: shimmerPhase))
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.12), lineWidth: 1)
                                )
                                .frame(width: 54, height: 54)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.3))
                                .overlay(RoundedRectangle(cornerRadius: 3).fill(shimmerGradient(phase: shimmerPhase)))
                                .frame(width: 38, height: 9)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: shimmerPhase)
    }

    private var skeletonSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.3))
                    .frame(width: 3, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 4).fill(shimmerGradient(phase: shimmerPhase)))
                    .frame(width: 80, height: 12)
                Spacer()
            }
            .padding(.leading, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 10) {
                            // Icon placeholder
                            Circle()
                                .fill(AppTheme.Colors.cardBackground.opacity(0.3))
                                .overlay(Circle().fill(shimmerGradient(phase: shimmerPhase)))
                                .frame(width: 28, height: 28)

                            // Title line
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.3))
                                .overlay(RoundedRectangle(cornerRadius: 3).fill(shimmerGradient(phase: shimmerPhase)))
                                .frame(width: 120, height: 11)

                            // Subtitle line
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.2))
                                .overlay(RoundedRectangle(cornerRadius: 3).fill(shimmerGradient(phase: shimmerPhase)))
                                .frame(width: 80, height: 9)
                        }
                        .padding(14)
                        .frame(width: 190, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: shimmerPhase)
    }

    private var skeletonRecentTripsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.Colors.borderSubtle.opacity(0.3))
                    .frame(width: 3, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 4).fill(shimmerGradient(phase: shimmerPhase)))
                    .frame(width: 90, height: 12)
                Spacer()
            }
            .padding(.leading, 20)

            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 12) {
                        // Route icon placeholder
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.3))
                            .overlay(RoundedRectangle(cornerRadius: 8).fill(shimmerGradient(phase: shimmerPhase)))
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 6) {
                            // Destination line
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.35))
                                .overlay(RoundedRectangle(cornerRadius: 3).fill(shimmerGradient(phase: shimmerPhase)))
                                .frame(width: CGFloat([160, 140, 180][index % 3]), height: 13)

                            // Subtitle line
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AppTheme.Colors.cardBackground.opacity(0.2))
                                .overlay(RoundedRectangle(cornerRadius: 3).fill(shimmerGradient(phase: shimmerPhase)))
                                .frame(width: CGFloat([110, 130, 100][index % 3]), height: 10)
                        }

                        Spacer()

                        // Time placeholder
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.2))
                            .overlay(RoundedRectangle(cornerRadius: 4).fill(shimmerGradient(phase: shimmerPhase)))
                            .frame(width: 48, height: 10)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.08), lineWidth: 0.5)
                            )
                    )
                    .padding(.horizontal, 16)
                }
            }
        }
        .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: shimmerPhase)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Helpers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.Colors.accent, AppTheme.Colors.accentSecondary],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 3, height: 14)
            SectionHeader(title: title, size: 13)
        }
        .padding(.leading, 20)
    }

    private func recColor(_ source: String) -> Color {
        switch source {
        case "calendar":     return AppTheme.Colors.warningYellow
        case "saved_place":  return AppTheme.Colors.accent
        case "recent_trip":  return AppTheme.Colors.successGreen
        case "saved_trip":   return AppTheme.Colors.accentSecondary
        default:             return AppTheme.Colors.accent
        }
    }

    private func recIcon(_ source: String) -> String {
        switch source {
        case "calendar":     return "calendar"
        case "saved_place":  return "house.fill"
        case "recent_trip":  return "clock.arrow.circlepath"
        case "saved_trip":   return "star.fill"
        default:             return "sparkles"
        }
    }

    private func recTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "h:mm a"
            return "Today \(f.string(from: date))"
        }
        f.dateFormat = "EEE h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Button Style

private struct PlanCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Dashed Connector Shape

private struct DashedConnector: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

#Preview {
    PlanView(
        locationManager: LocationManager(),
        homeViewModel: HomeViewModel(),
        selectedTab: .constant(.plan),
        cameraPosition: .constant(.userLocation),
        showStations: .constant(true),
        currentMapCenter: .constant(nil),
        currentMapDistance: .constant(nil)
    )
        .preferredColorScheme(.dark)
}
