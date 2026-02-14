//
//  WidgetSchedulesView.swift
//  Track
//
//  Manages activation schedules for the LiveNearMeWidget.
//  Users can add, edit, delete, and reorder schedules.
//

import SwiftUI
import WidgetKit

struct WidgetSchedulesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var schedules: [WidgetSchedule] = []
    @State private var showingEditor = false
    @State private var editingSchedule: WidgetSchedule?

    var body: some View {
        List {
            Section {
                if schedules.isEmpty {
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
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(schedules) { schedule in
                        scheduleRow(schedule)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingSchedule = schedule
                                showingEditor = true
                            }
                    }
                    .onDelete(perform: deleteSchedules)
                    .onMove(perform: moveSchedules)
                }
            } header: {
                Text("Active Schedules")
            } footer: {
                Text("Widget will activate at these times to show nearby transit for the configured duration.")
                    .font(.custom("Helvetica", size: 12))
            }

            Section {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(AppTheme.Colors.mtaBlue)
                    Text("Tip: Add schedules for your commute times to see nearby transit automatically.")
                        .font(.custom("Helvetica", size: 12))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("Widget Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingSchedule = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundColor(AppTheme.Colors.mtaBlue)
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .foregroundColor(AppTheme.Colors.mtaBlue)
            }
        }
        .sheet(isPresented: $showingEditor) {
            ScheduleEditorView(schedule: editingSchedule) { newSchedule in
                saveSchedule(newSchedule)
            }
        }
        .onAppear {
            loadSchedules()
        }
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
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func loadSchedules() {
        schedules = WidgetSchedule.loadAll()
    }

    private func saveSchedule(_ schedule: WidgetSchedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            // Update existing
            schedules[index] = schedule
        } else {
            // Add new
            schedules.append(schedule)
        }

        WidgetSchedule.saveAll(schedules)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func deleteSchedules(at offsets: IndexSet) {
        schedules.remove(atOffsets: offsets)
        WidgetSchedule.saveAll(schedules)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func moveSchedules(from source: IndexSet, to destination: Int) {
        schedules.move(fromOffsets: source, toOffset: destination)
        WidgetSchedule.saveAll(schedules)
    }

    private func toggleSchedule(_ schedule: WidgetSchedule, enabled: Bool) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index].enabled = enabled
        WidgetSchedule.saveAll(schedules)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#Preview {
    NavigationStack {
        WidgetSchedulesView()
    }
}
