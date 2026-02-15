//
//  WidgetSchedulesContentView.swift
//  Track
//
//  Widget schedules content for display within the universal bottom sheet.
//  Manages activation schedules for the LiveNearMeWidget.
//

import SwiftUI
import WidgetKit

/// Widget schedules content for display within the universal bottom sheet.
struct WidgetSchedulesContentView: View {
    let sheetNavigator: SheetNavigator
    @State private var schedules: [WidgetSchedule] = []
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Add button
                HStack {
                    Spacer()
                    Button {
                        sheetNavigator.navigate(to: .scheduleEditor(schedule: nil))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Schedule")
                        }
                        .font(.custom("Helvetica-Bold", size: 14))
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                
                // Schedules list
                if schedules.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                            Button {
                                sheetNavigator.navigate(to: .scheduleEditor(schedule: schedule))
                            } label: {
                                scheduleRow(schedule)
                            }
                            .buttonStyle(.plain)
                            
                            if index < schedules.count - 1 {
                                Divider()
                                    .padding(.leading, AppTheme.Layout.cardPadding)
                            }
                        }
                    }
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Layout.cornerRadius)
                    .padding(.horizontal, AppTheme.Layout.margin)
                }
                
                // Footer tip
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    Text("Tip: Add schedules for your commute times to see nearby transit automatically.")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, AppTheme.Layout.margin)
                .padding(.top, 8)
                
                Spacer()
                    .frame(height: 40)
            }
            .padding(.top, 8)
        }
        .background(AppTheme.Colors.background)
        .onAppear {
            loadSchedules()
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("No schedules configured")
                .font(.custom("Helvetica-Bold", size: 14))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("Tap + to add your first schedule")
                .font(.custom("Helvetica", size: 12))
                .foregroundColor(AppTheme.Colors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Schedule Row
    
    private func scheduleRow(_ schedule: WidgetSchedule) -> some View {
        HStack(spacing: 12) {
            // Days badges
            HStack(spacing: 4) {
                ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                    let dayAbbr = ["S", "M", "T", "W", "T", "F", "S"][day]
                    let isActive = schedule.days.contains(day)
                    
                    Text(dayAbbr)
                        .font(.custom("Helvetica-Bold", size: 11))
                        .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .background(isActive ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textSecondary.opacity(0.1))
                        .cornerRadius(6)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.formattedStartTime)
                    .font(.custom("Helvetica-Bold", size: 15))
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Text("\(schedule.duration) min duration")
                    .font(.custom("Helvetica", size: 12))
                    .foregroundColor(AppTheme.Colors.textSecondary)
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
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 12)
    }
    
    // MARK: - Actions
    
    private func loadSchedules() {
        schedules = WidgetSchedule.loadAll()
    }
    
    private func toggleSchedule(_ schedule: WidgetSchedule, enabled: Bool) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index].enabled = enabled
        WidgetSchedule.saveAll(schedules)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#Preview {
    WidgetSchedulesContentView(sheetNavigator: SheetNavigator())
}
