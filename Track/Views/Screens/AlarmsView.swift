// The Alarms tab — home for widget activation schedules and a small
// gallery of the live widget previews. All visuals drawn with WK kit.

import SwiftUI
import WidgetKit

struct AlarmsView: View {
    @State private var schedules: [WidgetSchedule] = []
    @State private var showingEditor = false
    @State private var editingSchedule: WidgetSchedule?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    galleryCard
                    scheduleCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(AppTheme.Gradients.surface.ignoresSafeArea())
            .navigationTitle("Schedules")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingSchedule = nil
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(AppTheme.Colors.accent)
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                ScheduleEditorView(schedule: editingSchedule) { newSchedule in
                    saveSchedule(newSchedule)
                }
            }
            .onAppear(perform: loadSchedules)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WK.LiveDot()
                Text("WIDGETS & SCHEDULES")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }
            Text("Tell Track when to surface nearby transit. Long-press a route in the Dashboard to start a Live Activity.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Gallery Card

    private var galleryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("LIVE PREVIEW")
            ZStack {
                RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                NearbyListWidgetView(
                    arrivals: AlarmsView.previewArrivals,
                    maxVisible: 3,
                    date: Date(),
                    isActive: true
                )
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius,
                                 style: .continuous)
                    .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    // MARK: - Schedule Card

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("ACTIVE SCHEDULES")
                Spacer()
                Text("\(schedules.count)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }

            if schedules.isEmpty {
                emptyScheduleState
            } else {
                VStack(spacing: 10) {
                    ForEach(schedules) { schedule in
                        scheduleRow(schedule)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingSchedule = schedule
                                showingEditor = true
                            }
                    }
                }
            }
        }
    }

    private var emptyScheduleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(AppTheme.Colors.textTertiary)
            Text("No schedules yet")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text("Tap + to schedule when widgets should activate.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppTheme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius,
                             style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius,
                             style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func scheduleRow(_ schedule: WidgetSchedule) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(formatTime(schedule.startTime))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(schedule.enabled
                                     ? AppTheme.Colors.textPrimary
                                     : AppTheme.Colors.textTertiary)
                HStack(spacing: 4) {
                    let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                        let label = dayLabels[day]
                        let isActive = schedule.days.contains(day) && schedule.enabled
                        Text(label)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(isActive ? .white
                                             : AppTheme.Colors.textTertiary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle()
                                    .fill(isActive
                                          ? AppTheme.Colors.accent
                                          : AppTheme.Colors.cardElevated)
                            )
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("\(schedule.duration) min")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textSecondary)
                Toggle("", isOn: enabledBinding(for: schedule))
                    .labelsHidden()
                    .tint(AppTheme.Colors.accent)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius,
                             style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WK.Tokens.surfaceRadius,
                             style: .continuous)
                .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                delete(schedule)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundColor(AppTheme.Colors.textTertiary)
    }

    // MARK: - Logic

    private func loadSchedules() {
        schedules = WidgetSchedule.loadAll()
    }

    private func saveSchedule(_ schedule: WidgetSchedule) {
        if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[idx] = schedule
        } else {
            schedules.append(schedule)
        }
        WidgetSchedule.saveAll(schedules)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func delete(_ schedule: WidgetSchedule) {
        schedules.removeAll { $0.id == schedule.id }
        WidgetSchedule.saveAll(schedules)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func enabledBinding(for schedule: WidgetSchedule) -> Binding<Bool> {
        Binding(
            get: { schedule.enabled },
            set: { newValue in
                guard let idx = schedules.firstIndex(where: { $0.id == schedule.id })
                else { return }
                schedules[idx].enabled = newValue
                WidgetSchedule.saveAll(schedules)
                WidgetCenter.shared.reloadAllTimelines()
            }
        )
    }

    private func formatTime(_ raw: String) -> String {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return raw }
        var comps = DateComponents()
        comps.hour = h; comps.minute = m
        guard let date = Calendar.current.date(from: comps) else { return raw }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Preview Data

    private static var previewArrivals: [NearbyArrival] {
        [
            NearbyArrival(routeId: "MTA NYCT_A", stopName: "Jay St-MetroTech",
                          direction: "Manhattan", minutesAway: 3, status: "On Time",
                          mode: "subway",
                          arrivalTime: Date().addingTimeInterval(180)),
            NearbyArrival(routeId: "MTA NYCT_C", stopName: "Jay St-MetroTech",
                          direction: "Manhattan", minutesAway: 7, status: "On Time",
                          mode: "subway",
                          arrivalTime: Date().addingTimeInterval(420)),
            NearbyArrival(routeId: "B44", stopName: "Nostrand Av/Av H",
                          direction: "Sheepshead Bay", minutesAway: 11, status: "On Time",
                          mode: "bus",
                          arrivalTime: Date().addingTimeInterval(660)),
        ]
    }
}

#Preview {
    AlarmsView()
}
