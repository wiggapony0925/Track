import Foundation
import SwiftUI

private struct DashboardNowKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    var dashboardNow: Date {
        get { self[DashboardNowKey.self] }
        set { self[DashboardNowKey.self] = newValue }
    }
}

enum DashboardRelativeTime {
    static func updatedText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds) sec ago" }

        let minutes = seconds / 60
        if minutes < 60 {
            return minutes == 1 ? "Updated 1 min ago" : "Updated \(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "Updated 1 hr ago" : "Updated \(hours) hr ago"
        }

        let days = hours / 24
        return days == 1 ? "Updated 1 day ago" : "Updated \(days) days ago"
    }
}