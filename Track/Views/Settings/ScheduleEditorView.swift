//
//  ScheduleEditorView.swift
//  Track
//
//  Editor for creating and modifying widget activation schedules.
//

import SwiftUI

struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let schedule: WidgetSchedule?
    let onSave: (WidgetSchedule) -> Void

    @State private var selectedDays: Set<Int>
    @State private var startTime: Date
    @State private var duration: Int
    @State private var enabled: Bool

    init(schedule: WidgetSchedule?, onSave: @escaping (WidgetSchedule) -> Void) {
        self.schedule = schedule
        self.onSave = onSave

        // Initialize state from existing schedule or defaults
        if let schedule = schedule {
            _selectedDays = State(initialValue: schedule.days)
            _duration = State(initialValue: schedule.duration)
            _enabled = State(initialValue: schedule.enabled)

            // Parse time string
            let components = schedule.startTime.split(separator: ":")
            if components.count == 2,
               let hour = Int(components[0]),
               let minute = Int(components[1]) {
                var dateComponents = DateComponents()
                dateComponents.hour = hour
                dateComponents.minute = minute
                _startTime = State(initialValue: Calendar.current.date(from: dateComponents) ?? Date())
            } else {
                _startTime = State(initialValue: Date())
            }
        } else {
            // Defaults for new schedule
            _selectedDays = State(initialValue: [1, 2, 3, 4, 5]) // Weekdays
            _startTime = State(initialValue: {
                var components = DateComponents()
                components.hour = 8
                components.minute = 30
                return Calendar.current.date(from: components) ?? Date()
            }())
            _duration = State(initialValue: 15)
            _enabled = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Days Selection
                Section {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                            dayButton(day: day)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Active Days")
                } footer: {
                    Text("Select which days this schedule should be active.")
                }

                // Start Time
                Section {
                    DatePicker("Time", selection: $startTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                } header: {
                    Text("Start Time")
                } footer: {
                    Text("Widget will activate at this time on selected days.")
                }

                // Duration
                Section {
                    Picker("Duration", selection: $duration) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("20 minutes").tag(20)
                        Text("30 minutes").tag(30)
                        Text("45 minutes").tag(45)
                        Text("60 minutes").tag(60)
                    }
                } header: {
                    Text("Duration")
                } footer: {
                    Text("How long the widget should stay active.")
                }

                // Preview
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(AppTheme.Colors.mtaBlue)
                            Text(previewText)
                                .font(.custom("Helvetica", size: 14))
                                .foregroundColor(AppTheme.Colors.textPrimary)
                        }

                        if let nextActivation = calculateNextActivation() {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(AppTheme.Colors.mtaBlue)
                                Text("Next activation: \(nextActivation, style: .relative)")
                                    .font(.custom("Helvetica", size: 13))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle(schedule == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSchedule()
                    }
                    .foregroundColor(AppTheme.Colors.mtaBlue)
                    .disabled(selectedDays.isEmpty)
                }
            }
        }
    }

    // MARK: - Day Button

    private func dayButton(day: Int) -> some View {
        let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let isSelected = selectedDays.contains(day)

        return Button {
            if isSelected {
                selectedDays.remove(day)
            } else {
                selectedDays.insert(day)
            }
        } label: {
            VStack(spacing: 4) {
                Text(dayLabels[day])
                    .font(.custom("Helvetica-Bold", size: 13))
                    .foregroundColor(isSelected ? .white : AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? AppTheme.Colors.mtaBlue : AppTheme.Colors.textSecondary.opacity(0.1))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var previewText: String {
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let sortedDays = selectedDays.sorted()

        let daysText: String
        if sortedDays == [1, 2, 3, 4, 5] {
            daysText = "Weekdays"
        } else if sortedDays == [0, 6] {
            daysText = "Weekends"
        } else if sortedDays == [0, 1, 2, 3, 4, 5, 6] {
            daysText = "Every day"
        } else if sortedDays.count == 1 {
            daysText = dayNames[sortedDays[0]]
        } else {
            daysText = sortedDays.map { ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$0] }.joined(separator: ", ")
        }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeText = timeFormatter.string(from: startTime)

        return "Active on \(daysText) at \(timeText) for \(duration) min"
    }

    private func calculateNextActivation() -> Date? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: startTime)
        guard let hour = components.hour, let minute = components.minute else { return nil }

        let timeString = String(format: "%02d:%02d", hour, minute)
        let tempSchedule = WidgetSchedule(
            days: selectedDays,
            startTime: timeString,
            duration: duration,
            enabled: true
        )

        return tempSchedule.nextActivationTime()
    }

    private func saveSchedule() {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: startTime)
        guard let hour = components.hour, let minute = components.minute else { return }

        let timeString = String(format: "%02d:%02d", hour, minute)

        let newSchedule = WidgetSchedule(
            id: schedule?.id ?? UUID(),
            days: selectedDays,
            startTime: timeString,
            duration: duration,
            enabled: enabled
        )

        onSave(newSchedule)
        dismiss()
    }
}

#Preview {
    ScheduleEditorView(schedule: nil) { _ in }
}
