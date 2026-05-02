// Floating overlay controls for the map including alert indicator,
// recenter button, and selected route banner.
// Redesigned with iOS 18 conventions: symbol effects, smooth
// spring animations, and a compact glassmorphic control island.

import CoreLocation
import SwiftUI

/// Floating controls overlay displayed above the map.
/// Contains alert indicator, recenter button, and route banner.
struct MapControlsOverlay: View {
    // MARK: - Dependencies

    let viewModel: HomeViewModel
    let locationManager: LocationManager
    @Binding var cameraPosition: TrackCameraPosition
    @Binding var sheetDetent: TrackSheetDetent
    let currentMapCenter: CLLocationCoordinate2D?
    let currentMapDistance: Double?
    @Binding var userTrackingMode: TrackUserTrackingMode

    /// Called when the user taps the recenter button — HomeView uses this
    /// to dismiss drag-to-search and snap back to the real GPS location.
    var onRecenter: (() -> Void)?

    /// Called when the user taps the alert bell — HomeView navigates to alerts page.
    var onAlertsTapped: (() -> Void)?

    /// Two-way binding to the `@AppStorage("drag_to_search")` flag in
    /// HomeView.  Lets the on-map toggle flip it without opening Settings.
    @Binding var dragToSearchEnabled: Bool

    /// Whether a drag-search session is currently active (overlay visible).
    var isDragSearchActive: Bool = false

    /// Called when the toggle button is tapped while a drag-search session
    /// is active — dismisses the session and recenters on the user.
    var onDismissDragSearch: (() -> Void)?

    /// Called when the user taps the X on the route banner — should
    /// tear down the route detail sheet and clear the route overlay.
    /// HomeView wires this to the same close logic used by the sheet's
    /// own dismiss button so behavior stays consistent.
    var onCloseRoute: (() -> Void)?

    /// Called when the user taps the alert pill on the route banner
    /// (only present when the selected route has active alerts).
    /// HomeView wires this to switch the route-detail sheet to its
    /// Alerts tab.
    var onRouteAlertTapped: (() -> Void)?

    // MARK: - Internal State

    /// Tracks whether the recenter button was just tapped for the
    /// symbol bounce effect.
    @State private var recenterBounce = false

    /// Pulsing alert badge animation.
    @State private var alertPulse = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // MARK: - Route Banner (top-left, below safe area)
                if viewModel.selectedRouteId != nil {
                    VStack {
                        selectedRouteBanner
                            .padding(.trailing, viewModel.isRouteDetailPresented ? AppTheme.Layout.margin : 60)
                            .padding(.leading, AppTheme.Layout.margin)
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                // MARK: - Map Control Island (top-right, below compass)
                // Hidden when route detail sheet is fully open — the sheet
                // provides its own close, 3D, recenter, and favorite buttons.
                if sheetDetent != .large && !viewModel.isRouteDetailPresented {
                    VStack {
                        HStack(alignment: .top) {
                            // ── Drag Search Toggle (top-left) ──
                            if viewModel.selectedRouteId == nil {
                                DragSearchToggleButton(
                                    isEnabled: $dragToSearchEnabled,
                                    isDragSearchActive: isDragSearchActive,
                                    onDismissSession: onDismissDragSearch
                                )
                                .transition(
                                    .opacity.combined(
                                        with: .scale(scale: 0.85, anchor: .topLeading)
                                    )
                                )
                            }

                            Spacer()
                            mapControlIsland
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 52) // Clear the MapLibre compass
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topTrailing)))
                }
            }
        }
    }

    // MARK: - Map Control Island

    /// Compact glassmorphic pill with alert and recenter controls.
    /// Uses SF Symbol effects and spring animations for polished feel.
    private var mapControlIsland: some View {
        VStack(spacing: 0) {
            // ── Alert Button ──
            controlButton(
                icon: alertIcon,
                tint: alertButtonTint,
                a11y: "Service alerts, \(viewModel.serviceAlerts.count) active"
            ) {
                onAlertsTapped?()
                HapticManager.impact(.medium)
            }

            controlDivider

            // ── Recenter / Tracking Button ──
            controlButton(
                icon: trackingIcon,
                tint: trackingTint,
                a11y: trackingA11y,
                isEnabled: true // Always enabled to allow cycling modes
            ) {
                cycleTrackingMode()
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.35))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            .white.opacity(0.16),
                            lineWidth: 0.5
                        )
                }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        // Alert badge — rendered outside the clipped shape.
        .overlay(alignment: .topTrailing) {
            alertBadge
        }
    }

    /// A single control button within the island.
    private func controlButton(
        icon: String,
        tint: Color,
        a11y: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isEnabled ? tint : AppTheme.Colors.textSecondary.opacity(0.45))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IslandButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(a11y)
        .accessibilityHint(isEnabled ? "" : "Map is already centered on your location")
    }

    /// Hairline divider between island controls.
    private var controlDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 28, height: 0.5)
    }

    // MARK: - Alert Badge

    /// The SF Symbol name for the alert button — filled when alerts exist.
    private var alertIcon: String {
        viewModel.serviceAlerts.isEmpty
            ? "bell"
            : "bell.badge.fill"
    }

    /// Alert button tint — neutral when empty, colored when active.
    private var alertButtonTint: Color {
        if viewModel.serviceAlerts.isEmpty {
            return AppTheme.Colors.textSecondary
        }
        return hasSevereAlerts
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }

    /// Whether any service alert is severe.
    private var hasSevereAlerts: Bool {
        viewModel.serviceAlerts.contains { $0.severity == "severe" }
    }

    /// Floating count badge for active service alerts.
    @ViewBuilder
    private var alertBadge: some View {
        if !viewModel.serviceAlerts.isEmpty {
            let count = min(viewModel.serviceAlerts.count, 99)
            Text("\(count)")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, count > 9 ? 5 : 0)
                .frame(minWidth: 18, minHeight: 18)
                .background {
                    Capsule()
                        .fill(hasSevereAlerts
                              ? AppTheme.Colors.alertRed
                              : AppTheme.Colors.warningYellow)
                        .shadow(color: (hasSevereAlerts
                                        ? AppTheme.Colors.alertRed
                                        : AppTheme.Colors.warningYellow).opacity(0.4),
                                radius: 4, x: 0, y: 2)
                }
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: viewModel.serviceAlerts.count)
        }
    }

    // MARK: - Tracking State

    private var trackingIcon: String {
        // If a route is selected, the button acts as a "fit route" button.
        if viewModel.selectedRouteId != nil {
            return "location.fill"
        }
        switch userTrackingMode {
        case .none: return "location.fill"
        case .follow: return "location.fill"
        case .followWithHeading: return "location.north.line.fill"
        }
    }

    private var trackingTint: Color {
        if viewModel.selectedRouteId != nil {
            return !isMapCenteredOnUser ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textSecondary.opacity(0.45)
        }
        switch userTrackingMode {
        case .none: return !isMapCenteredOnUser ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textSecondary.opacity(0.45)
        case .follow, .followWithHeading: return AppTheme.Colors.mtaBlue
        }
    }

    private var trackingA11y: String {
        if viewModel.selectedRouteId != nil { return "Fit route on screen" }
        switch userTrackingMode {
        case .none: return "Recenter on my location"
        case .follow: return "Track with compass"
        case .followWithHeading: return "Stop compass tracking"
        }
    }

    // MARK: - Computed Properties

    /// Color of the currently selected route.
    private var selectedRouteColor: Color {
        if let group = viewModel.selectedGroupedRoute, group.isBus {
            return AppTheme.BusColors.color(forServiceType: group.busServiceType)
        }
        if let group = viewModel.selectedGroupedRoute, let hex = group.colorHex {
            return Color(hex: hex)
        }
        if let group = viewModel.selectedGroupedRoute {
            return group.isBus
                ? AppTheme.BusColors.color(forServiceType: group.busServiceType)
                : AppTheme.SubwayColors.color(for: group.displayName)
        }
        return AppTheme.Colors.mtaBlue
    }

    /// True when the live map center is essentially the same as the
    /// user's current GPS location (within ~60m).  Used to dim/disable
    /// the recenter button — there's nothing to recenter to.
    private var isMapCenteredOnUser: Bool {
        guard let center = currentMapCenter,
              let user = locationManager.currentLocation?.coordinate
        else {
            return false
        }
        // Skip the check when drag-search has the camera over a chosen
        // anchor that isn't the user's GPS, or when a route is
        // selected (the route's fit camera is what "centered" means).
        if isDragSearchActive { return false }
        if viewModel.selectedRouteId != nil { return false }
        let a = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let b = CLLocation(latitude: user.latitude, longitude: user.longitude)
        return a.distance(from: b) < 60
    }

    // MARK: - Actions

    private func cycleTrackingMode() {
        // If a route is selected, keep the existing "fit route" behavior
        // instead of locking to the user.
        if viewModel.selectedRouteId != nil {
            centerMap()
            return
        }

        // Dismiss drag-to-search and restore real location data.
        onRecenter?()

        // Collapse the sheet to reveal the map.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            sheetDetent = SheetConstants.defaultDetent
        }

        // Cycle through the MapLibre tracking modes.
        switch userTrackingMode {
        case .none:
            userTrackingMode = .follow
        case .follow:
            userTrackingMode = .followWithHeading
        case .followWithHeading:
            userTrackingMode = .follow
        }

        HapticManager.impact(.light)
    }

    private func centerMap() {
        // Dismiss drag-to-search and restore real location data.
        onRecenter?()

        // Collapse the sheet to reveal the map.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            sheetDetent = SheetConstants.defaultDetent
        }

        // Determine the target camera — route-fit or user location.
        let targetCamera: TrackCameraPosition
        if viewModel.selectedRouteId != nil,
           let fitCamera = viewModel.cameraPositionFittingRoute(
               userLocation: locationManager.currentLocation,
               is3D: false
           ) {
            targetCamera = fitCamera
        } else {
            let userCoord = locationManager.currentLocation?.coordinate
            let finalTarget = userCoord ?? AppTheme.MapConfig.nycCenter
            targetCamera = MapCameraPresets.center(on: finalTarget, is3D: false)
        }

        // Apply camera through the central engine — dedupe + bounds
        // validation + renderer-echo mute live there. The sheet detent
        // change runs in its own transaction so its reactive
        // `handleSheetDetentChanged` write inside HomeView is dropped
        // by the engine's coalesce window (same target).
        CameraHoverEngine.commit(
            targetCamera,
            animation: HoverAnimations.routeFit,
            to: $cameraPosition,
            source: .user
        )

        HapticManager.impact(.light)
    }

    // MARK: - Selected Route Banner

    /// Live vehicle count for the currently filtered direction.
    private var bannerLiveCount: Int {
        if viewModel.selectedGroupedRoute?.isBus == true {
            return viewModel.filteredBusVehicles.count
        }
        return viewModel.filteredTrainVehicles.count
    }

    /// Route mode label for the banner — shows service type for buses.
    private var bannerModeLabel: String {
        guard let g = viewModel.selectedGroupedRoute else { return "" }
        if g.isLIRR { return "LIRR" }
        if g.isMNR { return "Metro-North" }
        if g.isBus {
            if let svc = g.busServiceType, svc != "Local" {
                return svc.uppercased()
            }
            return "BUS"
        }
        return "SUBWAY"
    }

    /// Terminal pair from direction headsigns (or first/last stops fallback).
    private var bannerTerminalPair: (String, String)? {
        guard let shape = compatibleRouteShape else { return nil }
        if shape.directions.count >= 2 {
            let a = shape.directions[0].headsign
            let b = shape.directions[1].headsign
            if !a.isEmpty && !b.isEmpty && a != b,
               !DirectionConstants.isFallbackDirection(a),
               !DirectionConstants.isFallbackDirection(b) {
                return (a, b)
            }
        }
        if let first = shape.stops.first?.name,
           let last = shape.stops.last?.name,
           first != last {
            return (first, last)
        }
        return nil
    }

    /// Headsign for the currently selected direction — the single destination
    /// the user is heading toward (e.g. "34 St-Hudson Yards" instead of the
    /// full terminal pair).  Falls back to the second terminal of the pair,
    /// then the last stop name.
    private var bannerDestinationHeadsign: String? {
        if let group = viewModel.selectedGroupedRoute,
           group.directions.indices.contains(viewModel.selectedDirectionIndex) {
            let idx = viewModel.selectedDirectionIndex
            let dir = group.directions[idx]
            let matchedDir = compatibleRouteShape?.matchedDirection(
                index: idx,
                name: dir.direction
            )
            let useShapeTerminal = !DirectionConstants.isFallbackDirection(matchedDir?.headsign ?? "")
            return ArrivalHelpers.resolveDirectionLabel(
                for: dir,
                shapeHeadsign: useShapeTerminal ? matchedDir?.headsign : nil,
                shapeLastStopName: useShapeTerminal ? matchedDir?.stops.last?.name : nil,
                skipBackendLabel: !group.isBus,
                skipArrivalDestinations: !group.isBus,
                useShortCompass: false
            )
        }
        if let pair = bannerTerminalPair {
            return pair.1
        }
        return compatibleRouteShape?.stops.last?.name
    }

    private var compatibleRouteShape: RouteShapeResponse? {
        guard let group = viewModel.selectedGroupedRoute,
              let shape = viewModel.routeShape
        else { return nil }
        return shape.isCompatible(
            withMode: group.mode,
            routeId: group.routeId,
            displayName: group.displayName
        ) ? shape : nil
    }

    /// Optional service-variant badge for the route header (Express,
    /// SBS, Limited, School).  Returns `nil` for plain Local bus or
    /// non-express subway so we don't clutter the header with a
    /// redundant tag.  Reuses the shared `ServiceTypeBadge` component.
    @ViewBuilder
    private var bannerServiceBadge: some View {
        if let group = viewModel.selectedGroupedRoute {
            if group.isBus {
                if let badge = ServiceTypeBadge.bus(serviceType: group.busServiceType) {
                    badge
                }
            } else if !group.isCommuterRail {
                // Subway: flag express variants like <6>, <7>, FX.
                let rid = group.displayName.uppercased()
                let isExpress = ["6X", "7X", "FX"].contains(rid)
                if let badge = ServiceTypeBadge.subway(isExpress: isExpress) {
                    badge
                }
            }
        }
    }

    /// Route alerts matching the selected route.
    private var bannerRouteAlerts: [TransitAlert] {
        guard let g = viewModel.selectedGroupedRoute else { return [] }
        let byId = viewModel.serviceAlerts.matching(routeId: g.routeId, mode: g.mode)
        let byName = viewModel.serviceAlerts.matching(routeId: g.displayName, mode: g.mode)
        var seen = Set<String>()
        return (byId + byName).filter { seen.insert($0.id).inserted }
    }

    /// Severity color for the most urgent route alert.
    private var bannerAlertColor: Color {
        bannerHasSevereAlert
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }

    /// Whether any of the route's active alerts is marked severe.
    private var bannerHasSevereAlert: Bool {
        bannerRouteAlerts.contains { $0.severity == "severe" }
    }

    // MARK: - Route Banner View

    /// Free-form route header that sits above the map.  A subtle
    /// `ultraThinMaterial` fog tinted with the route color provides
    /// just enough contrast for the text to read against any map
    /// background — without the heavy white card or per-glyph
    /// drop-shadows the previous design relied on.  A red close X
    /// floats in the top-right corner (matching the Trip Results
    /// dismiss button) so the user can always tear the route down.
    private var selectedRouteBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                if let group = viewModel.selectedGroupedRoute {
                    // Large bubble badge — drop shadow gives it lift
                    // against the live map without needing a card.
                    RouteBadge(
                        routeID: group.displayName.isEmpty
                            ? stripMTAPrefix(group.routeId)
                            : group.displayName,
                        size: .custom(56, 26),
                        hexColor: group.colorHex,
                        mode: group.mode,
                        busServiceType: group.busServiceType
                    )
                    .shadow(color: selectedRouteColor.opacity(0.45), radius: 10, y: 4)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        bannerServiceBadge
                        if bannerLiveCount > 0 {
                            liveIndicator
                        }
                    }

                    if let dest = bannerDestinationHeadsign {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(selectedRouteColor)
                            Text(dest)
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(selectedRouteColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.75)
                        }
                    } else if viewModel.routeShape == nil {
                        Text("Loading…")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                // Close X — red circle button (matches TripResultsView).
                // Sized to match `recenterRouteButton` in RouteDetailSheet
                // (42pt) so the right edges and centers line up cleanly
                // when both are visible on screen.
                if onCloseRoute != nil {
                    Button {
                        onCloseRoute?()
                        HapticManager.impact(.light)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background {
                                Circle()
                                    .fill(AppTheme.Colors.alertRed)
                                    .overlay(
                                        Circle().strokeBorder(
                                            .white.opacity(0.18), lineWidth: 0.8)
                                    )
                            }
                            .shadow(color: AppTheme.Colors.alertRed.opacity(0.34), radius: 8, y: 3)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    }
                    .buttonStyle(IslandButtonStyle())
                    .accessibilityLabel("Close route")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background {
                // Hand-drawn fog — several offset blurred blobs of
                // material + faint route tint, layered so the
                // silhouette is irregular (not a rectangle, not an
                // oval).  Like smudging fog onto the map with a
                // pencil.  No border, no card, no defined edge.
                ZStack {
                    Ellipse()
                        .fill(.ultraThinMaterial)
                        .frame(width: 320, height: 110)
                        .offset(x: -30, y: -4)
                        .blur(radius: 18)
                    Ellipse()
                        .fill(.ultraThinMaterial)
                        .frame(width: 220, height: 90)
                        .offset(x: 60, y: 10)
                        .blur(radius: 22)
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 140, height: 140)
                        .offset(x: -90, y: 6)
                        .blur(radius: 24)
                    // Route-color smudge — barely there, just enough
                    // to color the fog with the line's identity.
                    Ellipse()
                        .fill(selectedRouteColor.opacity(0.18))
                        .frame(width: 260, height: 90)
                        .offset(x: -10, y: 0)
                        .blur(radius: 28)
                    Ellipse()
                        .fill(selectedRouteColor.opacity(0.12))
                        .frame(width: 160, height: 70)
                        .offset(x: 70, y: 14)
                        .blur(radius: 24)
                }
                .allowsHitTesting(false)
            }

            // Alert strip — tappable summary pill that jumps to the
            // route-detail Alerts tab.  Uses MTA Mercury's `alertType`
            // ("Delays", "Suspended", "Reduced Service") for the label
            // so the banner stays one-glance — the full text lives in
            // the alerts tab.
            if let topAlert = bannerRouteAlerts.first {
                Button {
                    onRouteAlertTapped?()
                    HapticManager.impact(.medium)
                } label: {
                    alertStrip(
                        summary: alertSummary(for: topAlert),
                        color: bannerAlertColor,
                        extraCount: bannerRouteAlerts.count - 1,
                        isSevere: bannerHasSevereAlert
                    )
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel(
                    "\(bannerRouteAlerts.count) service \(bannerRouteAlerts.count == 1 ? "alert" : "alerts"). Tap for details."
                )
            } else if let inlineAlert = viewModel.selectedGroupedRoute?.alerts.first {
                Button {
                    onRouteAlertTapped?()
                    HapticManager.impact(.light)
                } label: {
                    alertStrip(
                        summary: inlineAlert.alertType ?? "Alert",
                        color: AppTheme.Colors.warningYellow,
                        extraCount: 0,
                        isSevere: false
                    )
                }
                .buttonStyle(IslandButtonStyle())
                .accessibilityLabel("Service alert. Tap for details.")
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }

    /// Pulsing live-vehicle count with recording dot.
    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AppTheme.Colors.successGreen)
                .frame(width: 5, height: 5)
                .shadow(color: AppTheme.Colors.successGreen.opacity(0.5), radius: 3)
            Text("\(bannerLiveCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Colors.successGreen)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(AppTheme.Colors.successGreen.opacity(0.14))
        }
        .overlay {
            Capsule().strokeBorder(AppTheme.Colors.successGreen.opacity(0.45), lineWidth: 0.6)
        }
    }

    /// Alert strip shown at the bottom of the route banner.
    /// Distill an alert down to a 1-2 word category badge label.
    /// Prefers MTA Mercury's `alertType` ("Delays",
    /// "Planned - Suspended", "Reduced Service"…), falling back to a
    /// keyword scan of the title so we never spill a paragraph into
    /// the map header.
    private func alertSummary(for alert: TransitAlert) -> String {
        if let raw = alert.alertType?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty {
            // "Planned - Suspended" → "Suspended" (drop the
            // "Planned - " prefix — the icon already conveys urgency).
            if let dash = raw.range(of: " - ") {
                return String(raw[dash.upperBound...])
            }
            return raw
        }
        let lower = alert.title.lowercased()
        if lower.contains("suspend") { return "Suspended" }
        if lower.contains("delay") { return "Delays" }
        if lower.contains("reroute") { return "Reroute" }
        if lower.contains("skip") || lower.contains("bypass") { return "Skipping Stops" }
        if lower.contains("crowd") { return "Crowded" }
        if lower.contains("weekend") { return "Weekend Work" }
        if lower.contains("planned") { return "Planned Work" }
        return "Alert"
    }

    private func alertStrip(
        summary: String,
        color: Color,
        extraCount: Int,
        isSevere: Bool
    ) -> some View {
        HStack(spacing: 6) {
            // Icon in a tiny white halo so it pops against the colored
            // capsule on every backdrop.
            ZStack {
                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 16, height: 16)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: isSevere)
            }

            Text(summary.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(.white)
                .lineLimit(1)

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        Capsule().fill(.white.opacity(0.95))
                    }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.30), lineWidth: 0.6)
        }
        .shadow(color: color.opacity(0.55), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
    }
}

// MARK: - Island Button Style

/// Press-down spring button style for the control island.
/// Provides a subtle scale-down + opacity shift on press.
private struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    let vm = HomeViewModel()
    let lm = LocationManager()
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        MapControlsOverlay(
            viewModel: vm,
            locationManager: lm,
            cameraPosition: .constant(.userLocation),
            sheetDetent: .constant(SheetConstants.defaultDetent),
            currentMapCenter: nil,
            currentMapDistance: nil,
            userTrackingMode: .constant(.none),
            onAlertsTapped: {},
            dragToSearchEnabled: .constant(true)
        )
    }
}
