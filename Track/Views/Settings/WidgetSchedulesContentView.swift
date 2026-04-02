// Widget schedules content for display within the universal bottom sheet.
// Manages activation schedules for the LiveNearMeWidget.
// Includes a visual preview of the widget so users can see
// what their settings produce.

import SwiftUI
import WidgetKit

/// Widget schedules content for display within the universal bottom sheet.
struct WidgetSchedulesContentView: View {
    let sheetNavigator: SheetNavigator
    @State private var schedules: [WidgetSchedule] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header with Back Button
            sheetHeader
            
            // MARK: - Scrollable Content
            ScrollView {
                VStack(spacing: 20) {
                    // Widget preview
                    widgetPreviewCard

                    // Info card
                    infoCard
                    
                    // Schedules list
                    if schedules.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(
                                Array(schedules.enumerated()),
                                id: \.element.id
                            ) { index, schedule in
                                Button {
                                    sheetNavigator.navigate(to: .scheduleEditor(schedule: schedule))
                                } label: {
                                    scheduleRow(schedule)
                                }
                                .buttonStyle(.plain)
                                
                                if index < schedules.count - 1 {
                                    Divider()
                                        .padding(.leading, AppTheme.Layout.cardPadding + 44)
                                }
                            }
                        }
                        .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
                        .padding(.horizontal, AppTheme.Layout.margin)
                    }
                    
                    Spacer()
                        .frame(height: 40)
                }
                .padding(.top, 12)
            }
        }
        .background(AppTheme.Gradients.screen)
        .onAppear {
            loadSchedules()
        }
    }
    
    // MARK: - Sheet Header
    
    private var sheetHeader: some View {
        HStack(spacing: 12) {
            // Back button
            Button {
                sheetNavigator.goBack()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Settings")
                        .font(AppTheme.Typography.navButton)
                }
                .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            
            Spacer()
            
            // Title
            Text("Schedules")
                .font(AppTheme.Typography.headerMedium)
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Spacer()
            
            // Add button
            Button {
                sheetNavigator.navigate(to: .scheduleEditor(schedule: nil))
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.vertical, 16)
        .background(AppTheme.Gradients.floating)
    }

    // MARK: - Widget Preview

    /// Shows the real widget medium views using placeholder data.
    /// TrackLiveBannerView lives in Shared/ so it compiles here without duplicating layout code.
    private var widgetPreviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Widget Preview")
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
                Text("Live")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundColor(AppTheme.Colors.alertRed)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.Colors.alertRed.opacity(0.12))
                    .clipShape(Capsule())
            }

            VStack(spacing: 16) {
                // Nearby Arrivals preview
                VStack(spacing: 8) {
                    widgetFrame {
                        NearbyListWidgetView.placeholder
                    }
                    Text("Nearby Arrivals")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }

            Text(
                "These previews match your widget layout."
                + " They update live every minute"
                + " on your home screen."
            )
                .font(AppTheme.Typography.settingsDescription)
                .foregroundColor(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Layout.cardPadding)
        .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }

    /// A rounded rectangle that mimics an iOS home screen medium widget slot.
    @ViewBuilder
    private func widgetFrame<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(AppTheme.Colors.glassHighlight.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: AppTheme.Colors.shadow.opacity(0.20), radius: 14, x: 0, y: 6)
            .shadow(color: AppTheme.Colors.shadowStrong.opacity(0.10), radius: 4, x: 0, y: 2)
    }

    
    // MARK: - Info Card
    
    private var infoCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.Gradients.tintWash(AppTheme.Colors.mtaBlue, intensity: 0.22))
                    .frame(
                        width: AppTheme.Layout.iconCircleSize,
                        height: AppTheme.Layout.iconCircleSize
                    )
                Image(systemName: "clock.badge.checkmark.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Automatic Activation")
                    .font(AppTheme.Typography.settingsTitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("Schedule when the widget shows nearby transit automatically.")
                    .font(AppTheme.Typography.settingsDescription)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Layout.cardPadding)
        .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppTheme.Gradients.tintWash(AppTheme.Colors.mtaBlue, intensity: 0.16))
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            
            VStack(spacing: 6) {
                Text("No Schedules Yet")
                    .font(AppTheme.Typography.routeLabel)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text(
                    "Add your first schedule to automatically"
                    + "\nshow transit info during your commute."
                )
                    .font(AppTheme.Typography.cardSubtitle)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                sheetNavigator.navigate(to: .scheduleEditor(schedule: nil))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Add Schedule")
                        .font(AppTheme.Typography.settingsTitle)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .trackAccentBackground(cornerRadius: AppTheme.Layout.searchBarCornerRadius)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Schedule Row
    
    private func scheduleRow(_ schedule: WidgetSchedule) -> some View {
        HStack(spacing: 14) {
            // Time indicator
            ZStack {
                Circle()
                    .fill(
                        schedule.enabled
                        ? AppTheme.Gradients.tintWash(
                            AppTheme.Colors.mtaBlue,
                            intensity: 0.22
                        )
                        : AppTheme.Gradients.tintWash(
                            AppTheme.Colors.textSecondary,
                            intensity: 0.12
                        )
                    )
                    .frame(
                        width: AppTheme.Layout.iconCircleSize,
                        height: AppTheme.Layout.iconCircleSize
                    )
                Image(systemName: "clock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(
                        schedule.enabled
                        ? AppTheme.Colors.mtaBlue
                        : AppTheme.Colors.textSecondary
                    )
            }
            
            VStack(alignment: .leading, spacing: 6) {
                // Time and duration
                HStack(spacing: 8) {
                    Text(schedule.formattedStartTime)
                        .font(AppTheme.Typography.cardTitle)
                        .foregroundColor(
                            schedule.enabled
                            ? AppTheme.Colors.textPrimary
                            : AppTheme.Colors.textSecondary
                        )
                    
                    Text("•")
                        .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.5))
                    
                    Text("\(schedule.duration) min")
                        .font(AppTheme.Typography.cardSubtitle)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                
                // Days badges
                HStack(spacing: 4) {
                    ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                        let dayAbbr = ["S", "M", "T", "W", "T", "F", "S"][day]
                        let isActive = schedule.days.contains(day)
                        let textColor = dayBadgeTextColor(
                            isActive: isActive,
                            enabled: schedule.enabled
                        )
                        let bgColor = dayBadgeBackgroundColor(
                            isActive: isActive,
                            enabled: schedule.enabled
                        )
                        
                        Text(dayAbbr)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(textColor)
                            .frame(width: 20, height: 20)
                            .background(bgColor)
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            // Enabled toggle
            Toggle("", isOn: Binding(
                get: { schedule.enabled },
                set: { newValue in
                    toggleSchedule(schedule, enabled: newValue)
                }
            ))
            .tint(AppTheme.Colors.mtaBlue)
            .labelsHidden()
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 14)
    }
    
    // MARK: - Actions
    
    private func loadSchedules() {
        schedules = WidgetSchedule.loadAll()
    }
    
    private func toggleSchedule(_ schedule: WidgetSchedule, enabled: Bool) {
        // Find and update the schedule
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index].enabled = enabled
        
        // Save to local storage
        WidgetSchedule.saveAll(schedules)
        
        // Sync to cloud in background
        Task {
            await SyncManager.shared.uploadSchedule(schedules[index])
        }
        
        // Refresh widget
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    // MARK: - Day Badge Colors
    
    /// Returns the text color for a day badge based on active/enabled state
    private func dayBadgeTextColor(isActive: Bool, enabled: Bool) -> Color {
        if !isActive {
            return AppTheme.Colors.textSecondary.opacity(0.3)
        }
        return enabled ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textSecondary
    }
    
    /// Returns the background color for a day badge based on active/enabled state
    private func dayBadgeBackgroundColor(isActive: Bool, enabled: Bool) -> Color {
        if !isActive {
            return Color.clear
        }
        return enabled
            ? AppTheme.Colors.mtaBlue.opacity(0.15)
            : AppTheme.Colors.textSecondary.opacity(0.1)
    }
}

#Preview {
    WidgetSchedulesContentView(sheetNavigator: SheetNavigator())
}
