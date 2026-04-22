import CoreLocation
import SwiftUI

struct StopDetailSheet: View {
    let selection: StopDetailSelection
    let sheetNavigator: SheetNavigator
    let currentLocation: CLLocationCoordinate2D?
    let serviceAlerts: [TransitAlert]

    @State private var viewModel: StopDetailViewModel

    init(
        selection: StopDetailSelection,
        sheetNavigator: SheetNavigator,
        currentLocation: CLLocationCoordinate2D? = nil,
        elevatorOutages: [ElevatorStatus] = [],
        serviceAlerts: [TransitAlert] = [],
        client: StopDetailClient = .live
    ) {
        self.selection = selection
        self.sheetNavigator = sheetNavigator
        self.currentLocation = currentLocation
        self.serviceAlerts = serviceAlerts
        _viewModel = State(
            initialValue: StopDetailViewModel(
                selection: selection,
                elevatorOutages: elevatorOutages,
                client: client
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    heroCard
                    alertsSection
                    departuresSection
                    accessibilitySection
                    sourceFooter
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .trackScreenBackground()
        .task(id: selection.id) {
            await viewModel.loadIfNeeded()
        }
    }

    private var sheetHeader: some View {
        ZStack {
            Text("Stop Details")
                .font(.custom("Helvetica-Bold", size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)

            HStack {
                Button {
                    sheetNavigator.goBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Back")
                            .font(.custom("Helvetica", size: 16))
                    }
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                }

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }

                    Button {
                        sheetNavigator.popToRoot()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 16)
        .background(AppTheme.Gradients.screen)
    }

    private var heroCard: some View {
        let tint = primaryTint

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(heroSubtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)

                if !selection.servedRoutes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(selection.servedRoutes) { route in
                                RouteBadge(
                                    routeID: route.displayName,
                                    size: .medium,
                                    mode: route.mode
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            HStack(spacing: 16) {
                infoPill(
                    icon: selection.kind.iconName,
                    title: selection.kind.title,
                    tint: tint
                )

                if let walk = walkSummary {
                    infoPill(
                        icon: "figure.walk",
                        title: walk,
                        tint: AppTheme.Colors.textSecondary
                    )
                }

                infoPill(
                    icon: accessibilityPillIcon,
                    title: accessibilitySummaryPillText,
                    tint: accessibilityPillTint
                )

                if viewModel.hasRealtimeDepartures {
                    infoPill(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Live",
                        tint: AppTheme.Colors.successGreen
                    )
                }
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.Colors.cardElevated)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private var departuresSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Departures",
                subtitle: departuresSubtitle
            )

            if viewModel.isLoading {
                VStack(spacing: 12) {
                    StopDetailSkeletonCard()
                    StopDetailSkeletonCard()
                }
            } else if let error = viewModel.errorMessage {
                errorCard(message: error)
            } else if viewModel.sections.isEmpty {
                emptyStateCard
            } else {
                ForEach(viewModel.sections) { section in
                    StopDepartureCard(section: section)
                }
            }
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "Accessibility",
                subtitle: accessibilitySectionSubtitle
            )

            // ADA Status Badge Card
            if let ada = viewModel.stationAccessibility {
                adaStatusCard(ada)
            }

            // Equipment Status Card (elevators & escalators)
            if let ada = viewModel.stationAccessibility, !ada.equipment.isEmpty {
                equipmentCard(ada)
            } else if !viewModel.accessibilityOutages.isEmpty {
                // Fallback: legacy outage display for bus stops or when rich data unavailable
                legacyOutagesCard
            } else if viewModel.stationAccessibility == nil {
                // Fallback: simple headline for bus or when accessibility data isn't loaded
                legacyStatusCard
            }
        }
    }

    private func adaStatusCard(_ ada: StationAccessibility) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // ADA badge row
            HStack(spacing: 10) {
                Image(systemName: ada.adaIconName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(adaStatusColor(ada.adaStatus))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ada.adaLabel)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textPrimary)

                    if ada.adaStatus == 2, !ada.adaNotes.isEmpty {
                        Text(ada.adaNotes)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    } else if ada.adaStatus == 0 {
                        Text("This station does not have step-free access.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer()
            }

            // Direction accessibility (for partially accessible)
            if ada.adaStatus == 2 {
                HStack(spacing: 16) {
                    directionBadge(
                        label: "Northbound",
                        accessible: ada.adaNorthbound
                    )
                    directionBadge(
                        label: "Southbound",
                        accessible: ada.adaSouthbound
                    )
                }
            }

            // Next accessible station info
            if ada.adaStatus == 0 || ada.adaStatus == 2 {
                if !ada.nextAccessibleNorth.isEmpty || !ada.nextAccessibleSouth.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: "Nearest Accessible", size: 11, weight: .bold, color: AppTheme.Colors.textSecondary)

                        if !ada.nextAccessibleNorth.isEmpty {
                            Label(ada.nextAccessibleNorth, systemImage: "arrow.up")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }
                        if !ada.nextAccessibleSouth.isEmpty {
                            Label(ada.nextAccessibleSouth, systemImage: "arrow.down")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .trackCardBackground(cornerRadius: 16)
    }

    @ViewBuilder
    private func equipmentCard(_ ada: StationAccessibility) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Equipment summary header
            HStack(spacing: 8) {
                if ada.totalElevators > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down.square.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("\(ada.activeElevators.count)/\(ada.totalElevators) elevators")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                    }
                }
                if ada.totalEscalators > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "stairs")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                        Text("\(ada.activeEscalators.count)/\(ada.totalEscalators) escalators")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                    }
                }
                Spacer()
            }

            // Individual equipment items
            ForEach(Array(ada.equipment.enumerated()), id: \.element.id) { index, eq in
                equipmentRow(eq)

                if index < ada.equipment.count - 1 {
                    Divider()
                        .overlay(AppTheme.Colors.borderSubtle)
                }
            }
        }
        .padding(14)
        .trackCardBackground(cornerRadius: 16)
    }

    private func equipmentRow(_ eq: EquipmentDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Status indicator dot
                Circle()
                    .fill(eq.isActive ? AppTheme.Colors.successGreen : AppTheme.Colors.alertRed)
                    .frame(width: 8, height: 8)

                // Equipment type + ADA badge
                HStack(spacing: 6) {
                    Text(eq.typeLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(eq.isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.alertRed)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    if eq.isAda {
                        Text("ADA")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(AppTheme.Colors.mtaBlue)
                            )
                    }
                }

                Spacer()

                Text(eq.isActive ? "In Service" : "Out of Service")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(eq.isActive ? AppTheme.Colors.successGreen : AppTheme.Colors.alertRed)
            }

            // Description
            Text(eq.displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Outage details
            if let outage = eq.outage {
                VStack(alignment: .leading, spacing: 2) {
                    if let reason = outage.reason, !reason.isEmpty {
                        Text("Reason: \(reason)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    if let since = outage.since, !since.isEmpty {
                        Text("Out since \(since)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    if let est = outage.estimatedReturn, !est.isEmpty {
                        Text("Est. return: \(est)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                }
            }

            // Alternative route for out-of-service ADA equipment
            if !eq.isActive, eq.isAda, !eq.alternativeRoute.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Travel Alternative", size: 11, weight: .bold, tracking: 0.6, color: AppTheme.Colors.alertRed)

                    Text(eq.alternativeRoute)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private func directionBadge(label: String, accessible: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: accessible ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accessible ? AppTheme.Colors.successGreen : AppTheme.Colors.alertRed)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill((accessible ? AppTheme.Colors.successGreen : AppTheme.Colors.alertRed).opacity(0.1))
        )
    }

    /// Legacy outage card — used for bus stops or when rich accessibility data isn't available.
    private var legacyOutagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.Colors.alertRed)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.accessibilityHeadline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(accessibilityBodyText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }

            VStack(spacing: 10) {
                ForEach(Array(viewModel.accessibilityOutages.enumerated()), id: \.offset) { index, outage in
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: outage.equipmentType, weight: .bold, color: AppTheme.Colors.alertRed)

                        Text(outage.description)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textPrimary)

                        if let outageSince = outage.outageSince,
                           !outageSince.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Out since \(outageSince)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if index != viewModel.accessibilityOutages.count - 1 {
                        Divider()
                            .overlay(AppTheme.Colors.borderSubtle)
                    }
                }
            }
        }
        .padding(14)
        .trackCardBackground(cornerRadius: 16)
    }

    /// Simple status card for when no rich data is available and no outages.
    private var legacyStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: viewModel.accessibilityOutages.isEmpty
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(viewModel.accessibilityOutages.isEmpty
                                     ? AppTheme.Colors.successGreen
                                     : AppTheme.Colors.alertRed)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.accessibilityHeadline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text(accessibilityBodyText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(14)
        .trackCardBackground(cornerRadius: 16)
    }

    private func adaStatusColor(_ status: Int) -> Color {
        switch status {
        case 1: return AppTheme.Colors.successGreen
        case 2: return .orange
        default: return AppTheme.Colors.alertRed
        }
    }

    private var sourceFooter: some View {
        Text(sourceFooterText)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.82))
            .padding(.horizontal, 4)
    }

    private func sectionHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(AppTheme.Colors.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
    }

    private func infoPill(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .lineLimit(1)
        }
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn’t load stop details", systemImage: "wifi.exclamationmark")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("Try Again")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppTheme.Gradients.accentVibrant)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .trackCardBackground(cornerRadius: 16)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No arrivals right now")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("No upcoming service found. Try refreshing in a moment.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .trackCardBackground(cornerRadius: 16)
    }

    private var heroSubtitle: String {
        var parts = [selection.kind.title]
        if let direction = selection.directionLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direction.isEmpty {
            parts.append(direction.localizedCapitalized)
        }
        if let distanceText {
            parts.append(distanceText)
        }
        return parts.joined(separator: " • ")
    }

    private var departuresSubtitle: String {
        if viewModel.isLoading {
            return "Loading live arrivals"
        }
        if let lastUpdatedText {
            return "Updated \(lastUpdatedText)"
        }
        if viewModel.totalArrivalCount > 0 {
            return "\(viewModel.totalArrivalCount) upcoming departures"
        }
        return "Live departures for this stop"
    }

    private var accessibilityBodyText: String {
        if let ada = viewModel.stationAccessibility {
            if ada.outageCount > 0 {
                return "Check elevator status before heading out."
            }
            switch ada.adaStatus {
            case 1: return "All elevators and escalators are operating normally."
            case 2: return "Accessible in one direction — see details below."
            default: return "Step-free access is not available at this station."
            }
        }

        switch selection.kind {
        case .bus:
            return viewModel.accessibilityOutages.isEmpty
                ? "Bus-stop accessibility advisories are clear right now."
                : "Accessibility alerts can change quickly, so check again before you go."
        default:
            return viewModel.accessibilityOutages.isEmpty
                ? "Elevator and escalator status is clear for the moment."
                : "Use these advisories to avoid inaccessible entrances before you head out."
        }
    }

    private var accessibilitySummaryPillText: String {
        if let ada = viewModel.stationAccessibility {
            if ada.outageCount > 0 {
                return "\(ada.outageCount) outage\(ada.outageCount == 1 ? "" : "s")"
            }
            return ada.adaLabel
        }
        if viewModel.accessibilityOutages.isEmpty {
            return "Status clear"
        }
        return "\(viewModel.accessibilityOutages.count) alert\(viewModel.accessibilityOutages.count == 1 ? "" : "s")"
    }

    private var accessibilityPillIcon: String {
        if let ada = viewModel.stationAccessibility {
            if ada.outageCount > 0 { return "exclamationmark.triangle.fill" }
            return ada.adaIconName
        }
        return viewModel.accessibilityOutages.isEmpty
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var accessibilityPillTint: Color {
        if let ada = viewModel.stationAccessibility {
            if ada.outageCount > 0 { return AppTheme.Colors.alertRed }
            return adaStatusColor(ada.adaStatus)
        }
        return viewModel.accessibilityOutages.isEmpty
            ? AppTheme.Colors.successGreen
            : AppTheme.Colors.alertRed
    }

    private var accessibilitySectionSubtitle: String {
        if let ada = viewModel.stationAccessibility {
            if ada.outageCount > 0 { return "Equipment outages" }
            switch ada.adaStatus {
            case 1: return "Fully accessible"
            case 2: return "Partially accessible"
            default: return "Not ADA-accessible"
            }
        }
        return viewModel.accessibilityOutages.isEmpty ? "Status looks clear" : "Advisories"
    }

    private var liveSummaryPillText: String {
        if viewModel.isLoading {
            return "Loading"
        }
        if viewModel.totalArrivalCount == 0 {
            return "No live departures"
        }
        if viewModel.hasRealtimeDepartures {
            return "Live departures"
        }
        return "Scheduled only"
    }

    private var primaryTint: Color {
        guard let firstRoute = selection.servedRoutes.first else {
            return AppTheme.Colors.mtaBlue
        }

        switch firstRoute.mode {
        case "bus":
            return AppTheme.BusColors.localBlue
        case "lirr":
            return AppTheme.CommuterRailColors.lirrBlue
        case "mnr":
            return AppTheme.CommuterRailColors.mnrBlue
        default:
            return AppTheme.SubwayColors.color(for: firstRoute.displayName)
        }
    }

    private var distanceMeters: CLLocationDistance? {
        guard let currentLocation else { return nil }
        let from = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
        let to = CLLocation(latitude: selection.latitude, longitude: selection.longitude)
        return from.distance(from: to)
    }

    private var distanceText: String? {
        guard let distanceMeters else { return nil }
        return formatDistanceImperial(distanceMeters, suffix: "away")
    }

    private var walkSummary: String? {
        guard let distanceMeters else { return nil }
        let minutes = max(1, Int((distanceMeters / 80.0).rounded()))
        return "\(minutes) min walk"
    }

    private var lastUpdatedText: String? {
        guard let lastUpdated = viewModel.lastUpdated else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: lastUpdated, relativeTo: Date())
    }

    private var sourceFooterText: String {
        switch selection.kind {
        case .bus:
            return "Live stop data uses your Track transit feeds and MTA bus arrivals."
        case .subway:
            return "Subway departures are filtered to the exact station footprint you tapped."
        case .lirr:
            return "LIRR departures are filtered to this stop from the live branch feed."
        case .mnr:
            return "Metro-North departures are filtered to this stop from the live line feed."
        }
    }

    private var relevantAlerts: [TransitAlert] {
        let normalizedRoutes = Set(
            selection.routeIDs.map { normalizeMTARouteToken($0).uppercased() }
        )
        guard !normalizedRoutes.isEmpty else { return [] }
        return serviceAlerts.filter { alert in
            let alertRoutes = alert.affectedRoutes.map {
                normalizeMTARouteToken($0).uppercased()
            }
            return alertRoutes.contains { normalizedRoutes.contains($0) }
        }
    }

    @ViewBuilder
    private var alertsSection: some View {
        let alerts = relevantAlerts
        if !alerts.isEmpty {
            CollapsibleAlertsView(alerts: alerts)
        }
    }
}

/// Shows the first alert always, with a "View X more" button
/// that expands to reveal the rest.
private struct CollapsibleAlertsView: View {
    let alerts: [TransitAlert]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Always show the first alert.
            StopAlertRow(alert: alerts[0])

            if alerts.count > 1 {
                if isExpanded {
                    ForEach(alerts.dropFirst()) { alert in
                        StopAlertRow(alert: alert)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded
                              ? "chevron.up"
                              : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isExpanded
                             ? "Show less"
                             : "View \(alerts.count - 1) more alert\(alerts.count - 1 == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(AppTheme.Colors.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(
                            cornerRadius: 10, style: .continuous
                        )
                        .fill(AppTheme.Colors.accent.opacity(0.08))
                    )
                }
            }
        }
    }
}

private struct StopAlertRow: View {
    let alert: TransitAlert

    private var alertColor: Color {
        alert.severity == "severe"
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(alertColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                if let alertType = alert.alertType,
                   !alertType.isEmpty {
                    SectionHeader(title: alertType, size: 10, tracking: 0.6, color: alertColor)
                }

                AlertRichText(
                    text: alert.title,
                    font: .system(size: 14, weight: .semibold),
                    color: AppTheme.Colors.textPrimary,
                    alertMode: alert.mode
                )

                if !alert.description.isEmpty,
                   alert.description != alert.title {
                    AlertRichText(
                        text: alert.description,
                        font: .system(size: 13, weight: .regular),
                        color: AppTheme.Colors.textSecondary,
                        alertMode: alert.mode,
                        lineLimit: 3
                    )
                }

                if let ts = alert.updatedAt {
                    HStack(spacing: 0) {
                        Text(Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
                        Text(" ago")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(alertColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(alertColor.opacity(0.15), lineWidth: 0.75)
        )
    }
}

private struct StopDepartureCard: View {
    let section: StopDetailViewModel.DepartureSection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RouteBadge(
                    routeID: section.route.displayName,
                    size: .medium,
                    mode: section.route.mode
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    Text("\(section.totalArrivalCount) departure\(section.totalArrivalCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                if index != 0 {
                    Divider()
                        .overlay(AppTheme.Colors.borderSubtle)
                        .padding(.horizontal, 18)
                }

                StopDepartureRowView(row: row)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
        }
        .trackCardBackground(cornerRadius: 16)
    }

    private var titleText: String {
        if section.route.mode == "subway" {
            return "\(section.route.displayName) Train"
        }
        return section.route.displayName
    }
}

private struct StopDepartureRowView: View {
    let row: StopDetailViewModel.DepartureRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.primaryText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .lineLimit(2)

                if let secondaryText = row.secondaryText, !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }

                if let statusText = row.statusText, !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(statusText.lowercased().contains("schedule")
                                         ? AppTheme.Colors.textSecondary
                                         : AppTheme.Colors.alertRed)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                ForEach(row.times) { time in
                    StopDepartureTimeChip(time: time)
                }
            }
        }
    }
}

private struct StopDepartureTimeChip: View {
    let time: StopDetailViewModel.DepartureTime

    /// Live label derived from `time.arrivalDate` so the stop-detail page
    /// stays in sync with the route detail / row chips. When no timestamp
    /// is available (e.g. cancelled / status-only entries) we fall back
    /// to the static label produced by the view model.
    private static func liveLabel(from date: Date, now: Date) -> String {
        let secs = date.timeIntervalSince(now)
        if secs <= 30 { return "Now" }
        let minutes = Int(ceil(secs / 60.0))
        return "\(minutes) min"
    }

    private var tint: Color {
        if time.isAlert { return AppTheme.Colors.alertRed }
        if time.isScheduledOnly { return AppTheme.Colors.textSecondary }
        if time.isImminent { return AppTheme.Colors.successGreen }
        return AppTheme.Colors.mtaBlue
    }

    var body: some View {
        if let date = time.arrivalDate {
            // Recompute every 15 s — same cadence as the row's expanded
            // detail chip, fast enough for a smooth countdown but cheap.
            TimelineView(.periodic(from: .now, by: 15.0)) { ctx in
                let label = Self.liveLabel(from: date, now: ctx.date)
                let isNow = label == "Now"
                chipBody(label: label, forceImminent: isNow)
            }
        } else {
            chipBody(label: time.label, forceImminent: time.isImminent)
        }
    }

    @ViewBuilder
    private func chipBody(label: String, forceImminent: Bool) -> some View {
        if forceImminent {
            Text(label)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(tint)
                )
        } else {
            Text(label)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(tint)
                .monospacedDigit()
        }
    }
}

private struct StopDetailSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Colors.textSecondary.opacity(0.14))
                .frame(width: 160, height: 22)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.Colors.textSecondary.opacity(0.10))
                .frame(height: 18)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.Colors.textSecondary.opacity(0.10))
                .frame(width: 220, height: 18)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.textSecondary.opacity(0.12))
                    .frame(width: 58, height: 28)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.textSecondary.opacity(0.12))
                    .frame(width: 72, height: 28)
            }
        }
        .padding(16)
        .trackCardBackground(cornerRadius: 16)
        .redacted(reason: .placeholder)
    }
}
