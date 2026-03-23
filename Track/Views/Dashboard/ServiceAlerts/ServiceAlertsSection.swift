//
//  ServiceAlertsSection.swift
//  Track
//
//  A modern, grouped service alerts section displayed in the dashboard.
//  Alerts are grouped by transit mode (Subway, Bus, LIRR, Metro-North)
//  and displayed in expandable cards with severity-based color coding.
//  Follows the app's glassmorphic card design system.
//

import SwiftUI

// MARK: - Section

/// Top-level alerts section that groups alerts by mode and shows a summary banner.
struct ServiceAlertsSection: View {
    let alerts: [TransitAlert]
    var lastUpdated: Date? = nil
    
    /// Group alerts by mode, maintaining a consistent display order.
    /// Within each mode, alerts are sorted by severity (severe first) then recency.
    private var groupedAlerts: [(mode: String, label: String, icon: String, alerts: [TransitAlert])] {
        let modeOrder = ["subway", "bus", "lirr", "mnr"]
        let grouped = Dictionary(grouping: alerts, by: \.mode)
        
        return modeOrder.compactMap { mode in
            guard let modeAlerts = grouped[mode], !modeAlerts.isEmpty else { return nil }
            let first = modeAlerts[0]
            let sorted = modeAlerts.sortedBySeverityAndTime()
            return (mode: mode, label: first.modeLabel, icon: first.modeIcon, alerts: sorted)
        }
    }
    
    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Section header with alert count
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.Colors.warningYellow)
                        
                        Text("SERVICE ALERTS")
                            .font(AppTheme.Typography.sectionHeader)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    
                    Spacer()
                    
                    // Last updated timestamp
                    if let lastUpdated {
                        Text(lastUpdated, style: .time)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    
                    // Total count badge
                    Text("\(alerts.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(severityColor(for: alerts))
                        )
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.top, 8)
                
                // Mode groups
                ForEach(groupedAlerts, id: \.mode) { group in
                    ServiceAlertModeGroup(
                        mode: group.mode,
                        label: group.label,
                        icon: group.icon,
                        alerts: group.alerts
                    )
                }
            }
        }
    }
    
    /// Returns red if any alert is severe, yellow otherwise.
    private func severityColor(for alerts: [TransitAlert]) -> Color {
        alerts.contains(where: { $0.severity == "severe" })
            ? AppTheme.Colors.alertRed
            : AppTheme.Colors.warningYellow
    }
}

// MARK: - Mode Group

/// An expandable card for one transit mode's alerts.
/// For subway and bus modes, alerts are further grouped by NYC borough
/// with collapsible sub-sections so you don't have to scroll through everything.
struct ServiceAlertModeGroup: View {
    let mode: String
    let label: String
    let icon: String
    let alerts: [TransitAlert]
    
    @State private var isExpanded = false
    
    /// Whether this mode should show borough sub-groups.
    private var showBoroughGroups: Bool {
        (mode == "subway" || mode == "bus") && alerts.count > 3
    }
    
    /// Show first 2 by default, expand to reveal the rest.
    private let previewCount = 2
    
    private var visibleAlerts: [TransitAlert] {
        isExpanded ? alerts : Array(alerts.prefix(previewCount))
    }
    
    private var hasMore: Bool {
        alerts.count > previewCount
    }
    
    private var modeColor: Color {
        switch mode {
        case "bus":   return AppTheme.Colors.mtaBlue
        case "lirr":  return AppTheme.CommuterRailColors.lirrBlue
        case "mnr":   return AppTheme.CommuterRailColors.mnrBlue
        default:      return AppTheme.Colors.subwayBlack
        }
    }
    
    /// Group alerts by borough, in a consistent order.
    private var boroughGroups: [(borough: String, alerts: [TransitAlert])] {
        let boroughOrder = ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island", "System-Wide"]
        let grouped = Dictionary(grouping: alerts) { BoroughMapper.borough(for: $0) }
        return boroughOrder.compactMap { borough in
            guard let boroughAlerts = grouped[borough], !boroughAlerts.isEmpty else { return nil }
            return (borough: borough, alerts: boroughAlerts)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode header bar
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(modeColor))
                
                Text(label)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                
                Text("(\(alerts.count))")
                    .font(.custom("Helvetica", size: 13))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                
                Spacer()
                
                if !showBoroughGroups && hasMore {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show Less" : "Show All")
                                .font(.custom("Helvetica", size: 12))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            
            Divider()
                .padding(.leading, AppTheme.Layout.cardPadding)
            
            // Content: borough sub-groups or flat list
            if showBoroughGroups {
                VStack(spacing: 0) {
                    ForEach(boroughGroups, id: \.borough) { group in
                        BoroughAlertSubGroup(
                            borough: group.borough,
                            alerts: group.alerts,
                            mode: mode,
                            modeColor: modeColor
                        )
                    }
                }
            } else {
                // Flat alert rows (for LIRR, MNR, or small subway/bus lists)
                VStack(spacing: 0) {
                    ForEach(Array(visibleAlerts.enumerated()), id: \.element.id) { index, alert in
                        ServiceAlertRow(alert: alert, mode: mode)
                        
                        if index < visibleAlerts.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.cardPadding + 34)
                        }
                    }
                }
            }
        }
        .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

// MARK: - Borough Sub-Group

/// A collapsible sub-section within a mode group, grouping alerts by NYC borough.
struct BoroughAlertSubGroup: View {
    let borough: String
    let alerts: [TransitAlert]
    let mode: String
    let modeColor: Color
    
    @State private var isExpanded = false
    
    private var boroughIcon: String {
        switch borough {
        case "Manhattan":     return "building.2.fill"
        case "Brooklyn":      return "tram.fill"
        case "Queens":        return "airplane"     // JFK/LGA
        case "Bronx":         return "leaf.fill"
        case "Staten Island": return "ferry.fill"
        default:              return "map.fill"
        }
    }
    
    /// Whether any alert in this borough is severe.
    private var hasSevere: Bool {
        alerts.contains(where: { $0.severity == "severe" })
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Borough header — tap to expand/collapse
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: boroughIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(modeColor)
                        .frame(width: 22, height: 22)
                    
                    Text(borough)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                    
                    // Alert count with severity color
                    Text("\(alerts.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                hasSevere ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
                            )
                        )
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, AppTheme.Layout.cardPadding)
                .padding(.vertical, 8)
                .background(modeColor.opacity(0.04))
            }
            .buttonStyle(.plain)
            
            // Expanded alert rows
            if isExpanded {
                Divider()
                    .padding(.leading, AppTheme.Layout.cardPadding + 30)
                
                VStack(spacing: 0) {
                    ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                        ServiceAlertRow(alert: alert, mode: mode)
                        
                        if index < alerts.count - 1 {
                            Divider()
                                .padding(.leading, AppTheme.Layout.cardPadding + 34)
                        }
                    }
                }
            }
            
            Divider()
                .padding(.leading, AppTheme.Layout.cardPadding)
        }
    }
}

// MARK: - Borough Mapper

/// Maps MTA route IDs to NYC boroughs.
/// Subway lines are mapped by their primary service area.
/// Bus routes use their MTA prefix (Bx, B, M, Q, S).
/// Many subway lines span multiple boroughs — we use the borough
/// where the line is most associated or starts.
enum BoroughMapper {
    
    /// Determine the primary borough for a transit alert.
    static func borough(for alert: TransitAlert) -> String {
        guard let routeId = alert.routeId, !routeId.isEmpty else {
            return "System-Wide"
        }
        
        if alert.mode == "bus" {
            return boroughForBusRoute(routeId)
        }
        
        if alert.mode == "subway" {
            return boroughForSubwayLine(routeId)
        }
        
        return "System-Wide"
    }
    
    /// Bus routes use MTA borough prefixes:
    /// Bx = Bronx, B = Brooklyn, M = Manhattan, Q = Queens, S/SIM = Staten Island
    private static func boroughForBusRoute(_ routeId: String) -> String {
        let upper = routeId.uppercased()
        if upper.hasPrefix("BX") { return "Bronx" }
        if upper.hasPrefix("SIM") || (upper.hasPrefix("S") && !upper.hasPrefix("SI") && upper.dropFirst().first?.isNumber == true && upper.count <= 4) {
            // S + number with short length could be Staten Island or shuttle
            // SIM is definitely Staten Island
            return "Staten Island"
        }
        if upper.hasPrefix("S") && upper.count >= 3 && upper.dropFirst().first?.isLetter == true {
            // SI prefixed → Staten Island
            if upper.hasPrefix("SI") { return "Staten Island" }
        }
        if upper.hasPrefix("B") && !upper.hasPrefix("BX") && !upper.hasPrefix("BM") {
            return "Brooklyn"
        }
        if upper.hasPrefix("BM") { return "Brooklyn" } // Brooklyn-Manhattan express
        if upper.hasPrefix("M") { return "Manhattan" }
        if upper.hasPrefix("Q") { return "Queens" }
        if upper.hasPrefix("X") { return "Manhattan" } // Express buses
        return "System-Wide"
    }
    
    /// Subway lines mapped to primary borough association.
    /// Lines that span many boroughs use the borough most associated.
    private static func boroughForSubwayLine(_ routeId: String) -> String {
        let line = routeId.uppercased()
        
        // Manhattan-centric lines
        let manhattan: Set<String> = ["1", "2", "3", "C", "E", "S", "SI"]
        // Brooklyn-centric lines
        let brooklyn: Set<String> = ["B", "D", "F", "G", "N", "R", "W"]
        // Queens-centric lines
        let queens: Set<String> = ["7", "E", "M"]
        // Bronx-centric lines
        let bronx: Set<String> = ["4", "5", "6"]
        // Lines heavily serving both (we pick one)
        let crossBorough: [String: String] = [
            "A": "Manhattan",   // A runs Manhattan ↔ Queens/Brooklyn — most iconic in Manhattan
            "J": "Brooklyn",
            "Z": "Brooklyn",
            "L": "Brooklyn",
            "Q": "Brooklyn",    // Q train, not bus
        ]
        
        if let mapped = crossBorough[line] { return mapped }
        if bronx.contains(line) { return "Bronx" }
        if queens.contains(line) { return "Queens" }
        if brooklyn.contains(line) { return "Brooklyn" }
        if manhattan.contains(line) { return "Manhattan" }
        
        // SIR (Staten Island Railway)
        if line == "SIR" || line == "SI" { return "Staten Island" }
        
        return "System-Wide"
    }
}

// MARK: - Alert Row

/// A single alert row with route badge, severity indicator, and description.
struct ServiceAlertRow: View {
    let alert: TransitAlert
    let mode: String
    
    @State private var showFullDescription = false
    
    private var severityColor: Color {
        alert.severity == "severe" ? AppTheme.Colors.alertRed : AppTheme.Colors.warningYellow
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Left: route badge or severity icon
                if let routeId = alert.routeId, !routeId.isEmpty {
                    RouteBadge(
                        routeID: routeId,
                        size: .small,
                        isBus: mode == "bus",
                        mode: mode
                    )
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(severityColor)
                        .frame(width: 26, height: 26)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(alert.title)
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .lineLimit(showFullDescription ? nil : 2)
                    
                    // Description
                    if !alert.description.isEmpty {
                        Text(alert.description)
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .lineLimit(showFullDescription ? nil : 2)
                    }
                    
                    // Severity badge + timestamp
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(severityColor)
                                .frame(width: 6, height: 6)
                            
                            Text(alert.severity == "severe" ? "Severe" : "Warning")
                                .font(.custom("Helvetica", size: 11))
                                .foregroundColor(severityColor)
                        }
                        
                        if let ts = alert.updatedAt {
                            HStack(spacing: 0) {
                                Text(Date(timeIntervalSince1970: TimeInterval(ts)), style: .relative)
                                Text(" ago")
                            }
                            .font(.custom("Helvetica", size: 10))
                            .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
                        }

                        if let end = alert.activePeriodEnd {
                            let expiry = Date(timeIntervalSince1970: TimeInterval(end))
                            if expiry > Date() {
                                HStack(spacing: 2) {
                                    Image(systemName: "clock.badge.xmark")
                                        .font(.system(size: 9, weight: .medium))
                                    Text("Expires")
                                    Text(expiry, style: .relative)
                                }
                                .font(.custom("Helvetica", size: 10))
                                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.55))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Layout.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFullDescription.toggle()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Service Alerts") {
    ScrollView {
        ServiceAlertsSection(alerts: [
            TransitAlert(
                routeId: "A",
                title: "A train running with delays",
                description: "Southbound A trains are running with delays due to signal problems at 59 St-Columbus Circle.",
                severity: "warning",
                mode: "subway"
            ),
            TransitAlert(
                routeId: "1",
                title: "Service suspended between 96 St and South Ferry",
                description: "1 train service is suspended in both directions between 96 St and South Ferry due to a signal malfunction.",
                severity: "severe",
                mode: "subway"
            ),
            TransitAlert(
                routeId: "B63",
                title: "B63 route detoured",
                description: "B63 buses are detoured in both directions via Atlantic Ave due to road construction.",
                severity: "warning",
                mode: "bus"
            ),
            TransitAlert(
                routeId: "LIRR_1",
                title: "Babylon Branch delays up to 20 min",
                description: "Trains on the Babylon Branch are experiencing delays of up to 20 minutes.",
                severity: "severe",
                mode: "lirr"
            ),
        ])
    }
    .background(AppTheme.Colors.background)
}
