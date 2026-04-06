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
                    icon: viewModel.accessibilityOutages.isEmpty
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill",
                    title: accessibilitySummaryPillText,
                    tint: viewModel.accessibilityOutages.isEmpty
                        ? AppTheme.Colors.successGreen
                        : AppTheme.Colors.alertRed
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
                subtitle: viewModel.accessibilityOutages.isEmpty ? "Status looks clear" : "Advisories"
            )

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

                if !viewModel.accessibilityOutages.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.accessibilityOutages.enumerated()), id: \.offset) { index, outage in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(outage.equipmentType)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(AppTheme.Colors.alertRed)
                                    .textCase(.uppercase)
                                    .tracking(0.8)

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
            }
            .padding(14)
            .trackCardBackground(cornerRadius: 16)
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
        if viewModel.accessibilityOutages.isEmpty {
            return "Status clear"
        }
        return "\(viewModel.accessibilityOutages.count) alert\(viewModel.accessibilityOutages.count == 1 ? "" : "s")"
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
                    Text(alertType.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(alertColor)
                        .tracking(0.6)
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

    private var tint: Color {
        if time.isAlert { return AppTheme.Colors.alertRed }
        if time.isScheduledOnly { return AppTheme.Colors.textSecondary }
        if time.isImminent { return AppTheme.Colors.successGreen }
        return AppTheme.Colors.mtaBlue
    }

    var body: some View {
        if time.isImminent {
            Text(time.label)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(tint)
                )
        } else {
            Text(time.label)
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
