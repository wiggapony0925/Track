//
//  AlertNotificationManager.swift
//  Track
//
//  Manages local push notifications for MTA service alerts.
//  Tracks which alerts have already been notified so users only
//  receive one notification per new alert.
//

import Foundation
@preconcurrency import UserNotifications

/// Handles local notification delivery for new service alerts.
@MainActor
final class AlertNotificationManager {
    static let shared = AlertNotificationManager()

    /// IDs of alerts we've already sent a notification for (persisted per session).
    private var notifiedAlertIDs: Set<String> = []

    /// Previously known alert IDs — used to detect *new* alerts.
    private var previousAlertIDs: Set<String> = []

    private init() {}

    // MARK: - Permission

    /// Request notification authorization. Call once at app launch.
    func requestPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            }
        }
    }

    // MARK: - Process New Alerts

    /// Compare incoming alerts with known set and fire local notifications
    /// for any that are new. Returns the count of **new** alerts this cycle.
    @discardableResult
    func processAlerts(_ alerts: [TransitAlert]) -> Int {
        let currentIDs = Set(alerts.map(\.id))

        // First call — seed the set without spamming notifications
        guard !previousAlertIDs.isEmpty else {
            previousAlertIDs = currentIDs
            notifiedAlertIDs = currentIDs
            return 0
        }

        let newIDs = currentIDs.subtracting(previousAlertIDs)
        previousAlertIDs = currentIDs

        guard !newIDs.isEmpty else { return 0 }

        let newAlerts = alerts.filter { newIDs.contains($0.id) }
        for alert in newAlerts where !notifiedAlertIDs.contains(alert.id) {
            scheduleNotification(for: alert)
            notifiedAlertIDs.insert(alert.id)
        }

        return newAlerts.count
    }

    // MARK: - Notification Scheduling

    private func scheduleNotification(for alert: TransitAlert) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.modeLabel) Alert"
        if let route = alert.routeId {
            content.subtitle = "\(route) — \(alert.severity == "severe" ? "⚠️ Severe" : "Warning")"
        }
        content.body = alert.title
        content.sound = alert.severity == "severe"
            ? .defaultCritical
            : .default
        content.categoryIdentifier = "SERVICE_ALERT"
        content.userInfo = ["alertId": alert.id, "mode": alert.mode]

        // Deliver immediately
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "alert-\(alert.id)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[ALERT_NOTIF] Failed to schedule: \(error.localizedDescription)")
            }
        }
    }

    /// Clear the badge and all delivered alert notifications.
    func clearDelivered() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}
