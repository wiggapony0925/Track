//
//  WidgetSchedule.swift
//  Shared
//
//  Model for configurable widget activation schedules.
//  Users can set specific days/times when the LiveNearMeWidget should be active.
//

import Foundation

struct WidgetSchedule: Codable, Identifiable {
    let id: UUID
    var days: Set<Int> // 0=Sunday, 1=Monday, ..., 6=Saturday
    var startTime: String // "HH:mm" format (e.g., "08:30")
    var duration: Int // minutes
    var enabled: Bool

    init(id: UUID = UUID(), days: Set<Int>, startTime: String, duration: Int = 15, enabled: Bool = true) {
        self.id = id
        self.days = days
        self.startTime = startTime
        self.duration = duration
        self.enabled = enabled
    }

    // MARK: - Schedule Logic

    /// Check if this schedule is currently active at the given date
    func isActive(at date: Date = Date()) -> Bool {
        guard enabled else { return false }

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date) - 1 // Convert to 0-based

        // Check if today is an active day
        guard days.contains(weekday) else { return false }

        // Parse start time
        guard let scheduleStart = startTimeAsDate(on: date) else { return false }

        // Calculate end time
        let scheduleEnd = calendar.date(byAdding: .minute, value: duration, to: scheduleStart)!

        // Check if current time is within [start, end)
        return date >= scheduleStart && date < scheduleEnd
    }

    /// Find the next activation time after the given date
    func nextActivationTime(after date: Date = Date()) -> Date? {
        guard enabled, !days.isEmpty else { return nil }

        let calendar = Calendar.current

        // Try today first
        if let todayActivation = nextActivationOnSameDay(date: date), todayActivation > date {
            return todayActivation
        }

        // Look ahead up to 7 days
        for dayOffset in 1...7 {
            guard let futureDate = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let futureWeekday = calendar.component(.weekday, from: futureDate) - 1

            if days.contains(futureWeekday), let activation = startTimeAsDate(on: futureDate) {
                return activation
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// Convert start time string to Date on the given day
    private func startTimeAsDate(on date: Date) -> Date? {
        let components = startTime.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else {
            return nil
        }

        let calendar = Calendar.current
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.hour = hour
        dateComponents.minute = minute
        dateComponents.second = 0

        return calendar.date(from: dateComponents)
    }

    /// Find next activation on the same day (if not passed yet)
    private func nextActivationOnSameDay(date: Date) -> Date? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date) - 1

        guard days.contains(weekday), let activation = startTimeAsDate(on: date) else {
            return nil
        }

        return activation
    }

    /// Format days for display (e.g., "M T W T F" for weekdays)
    var daysDisplayString: String {
        let dayAbbreviations = ["S", "M", "T", "W", "T", "F", "S"]
        return days.sorted().map { dayAbbreviations[$0] }.joined(separator: " ")
    }

    /// Format start time for display (e.g., "8:30 AM")
    var formattedStartTime: String {
        let components = startTime.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else {
            return startTime
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        if let date = Calendar.current.date(from: dateComponents) {
            return formatter.string(from: date)
        }

        return startTime
    }
}

// MARK: - Collection Helpers

extension Array where Element == WidgetSchedule {
    /// Check if any schedule is currently active
    func hasActiveSchedule(at date: Date = Date()) -> Bool {
        return self.contains { $0.isActive(at: date) }
    }

    /// Find the next activation time across all schedules
    func nextActivation(after date: Date = Date()) -> Date? {
        return self.compactMap { $0.nextActivationTime(after: date) }.min()
    }

    /// Calculate when the current active period ends
    func activeUntil(from date: Date = Date()) -> Date? {
        let activeSchedules = self.filter { $0.isActive(at: date) }

        guard !activeSchedules.isEmpty else { return nil }

        // Find the latest end time among active schedules
        let calendar = Calendar.current
        let endTimes = activeSchedules.compactMap { schedule -> Date? in
            guard let startTime = startTimeHelper(on: date, schedule: schedule) else { return nil }
            return calendar.date(byAdding: .minute, value: schedule.duration, to: startTime)
        }

        return endTimes.max()
    }

    // Helper to parse start time for a schedule
    private func startTimeHelper(on date: Date, schedule: WidgetSchedule) -> Date? {
        let components = schedule.startTime.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else {
            return nil
        }

        let calendar = Calendar.current
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dateComponents.hour = hour
        dateComponents.minute = minute
        dateComponents.second = 0

        return calendar.date(from: dateComponents)
    }
}

// MARK: - Persistence

extension WidgetSchedule {
    private static let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? UserDefaults.standard
    private static let schedulesKey = "widget_schedules"

    /// Load all schedules from UserDefaults
    static func loadAll() -> [WidgetSchedule] {
        guard let data = defaults.data(forKey: schedulesKey) else { return [] }

        do {
            let schedules = try JSONDecoder().decode([WidgetSchedule].self, from: data)
            return schedules
        } catch {
            print("Failed to decode schedules: \(error)")
            return []
        }
    }

    /// Save schedules array to UserDefaults
    static func saveAll(_ schedules: [WidgetSchedule]) {
        do {
            let data = try JSONEncoder().encode(schedules)
            defaults.set(data, forKey: schedulesKey)
        } catch {
            print("Failed to encode schedules: \(error)")
        }
    }
}
