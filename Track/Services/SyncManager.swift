//
//  SyncManager.swift
//  Track
//
//  Manages synchronization between local storage and Supabase cloud.
//  Implements an offline-first approach where data is always available
//  locally and synced to the cloud when connected.
//
//  Currently syncs:
//  - Widget schedules (cross-device sync)
//  - User settings (cross-device sync)
//  - Favorites (cross-device sync)
//  - Commute patterns (smart suggestions)
//

import Foundation
import Combine

/// Manages sync between local storage and Supabase cloud
@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    /// Internal sync state — not @Published to avoid unnecessary view re-renders.
    /// Views that need sync status should use dedicated properties.
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    
    private let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
    private let lastSyncKey = "last_sync_date"
    
    private init() {
        lastSyncDate = defaults.object(forKey: lastSyncKey) as? Date
    }
    
    // MARK: - Full Sync
    
    /// Performs a full sync of all user data
    func performFullSync() async {
        guard SupabaseManager.shared.isAuthenticated else {
            AppLogger.shared.log("SYNC", message: "Skipping sync - not authenticated")
            return
        }
        
        isSyncing = true
        syncError = nil
        
        do {
            // Run independent sync operations in parallel to reduce
            // startup network contention (was ~2-5s sequential).
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    try await self.syncSchedules()
                }
                group.addTask { @MainActor in
                    try await self.pullUserSettings()
                }
                group.addTask { @MainActor in
                    await FavoritesManager.shared.refresh()
                }
                group.addTask { @MainActor in
                    await self.pullCommutePatterns()
                }
                try await group.waitForAll()
            }

            // Push local settings after pull completes to avoid race conditions
            await pushUserSettings()
            
            // Update last sync date
            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: lastSyncKey)
            
            AppLogger.shared.log("SYNC", message: "Sync completed successfully")
            
        } catch {
            syncError = error.localizedDescription
            AppLogger.shared.logError("SyncManager.performFullSync", error: error)
        }
        
        isSyncing = false
    }
    
    // MARK: - Schedules Sync
    
    /// Downloads schedules from Supabase and saves to local storage
    func syncSchedules() async throws {
        let cloudSchedules = try await SupabaseManager.shared.fetchSchedules()
        
        // Convert cloud format to local WidgetSchedule format
        let localSchedules: [WidgetSchedule] = cloudSchedules.compactMap { cloud in
            guard let id = cloud.id else { return nil }
            
            // Convert time string "HH:mm:ss" to "HH:mm"
            let startTime = parseTimeString(cloud.startTime)
            
            return WidgetSchedule(
                id: id,
                days: Set(cloud.daysOfWeek),
                startTime: startTime,
                duration: cloud.durationMinutes ?? 15,
                enabled: cloud.isEnabled ?? true,
                routeId: cloud.routeId,
                direction: cloud.direction
            )
        }
        
        // Only overwrite if we got data from cloud
        if !cloudSchedules.isEmpty {
            WidgetSchedule.saveAll(localSchedules)
            #if DEBUG
            print("[SyncManager] Synced \(localSchedules.count) schedules from cloud")
            #endif
        }
    }
    
    /// Uploads a schedule to Supabase (call when user creates/edits a schedule)
    func uploadSchedule(_ schedule: WidgetSchedule) async {
        guard let userIdString = defaults.string(forKey: "supabase_user_id"),
              let userId = UUID(uuidString: userIdString) else {
            #if DEBUG
            print("[SyncManager] Cannot upload schedule - not authenticated")
            #endif
            return
        }
        
        // Convert startTime "HH:mm" to "HH:mm:00" for Supabase TIME type
        let startTime = schedule.startTime + ":00"
        
        let cloudSchedule = CloudSchedule(
            id: schedule.id,
            userId: userId,
            daysOfWeek: Array(schedule.days).sorted(),
            startTime: startTime,
            durationMinutes: schedule.duration,
            routeId: schedule.routeId,
            direction: schedule.direction,
            isEnabled: schedule.enabled
        )
        
        do {
            try await SupabaseManager.shared.upsertSchedule(cloudSchedule)
            #if DEBUG
            print("[SyncManager] Uploaded schedule \(schedule.id)")
            #endif
        } catch {
            #if DEBUG
            print("[SyncManager] Failed to upload schedule: \(error)")
            #endif
        }
    }
    
    /// Deletes a schedule from Supabase
    func deleteSchedule(_ scheduleId: UUID) async {
        do {
            try await SupabaseManager.shared.deleteSchedule(id: scheduleId)
            #if DEBUG
            print("[SyncManager] Deleted schedule \(scheduleId)")
            #endif
        } catch {
            #if DEBUG
            print("[SyncManager] Failed to delete schedule: \(error)")
            #endif
        }
    }
    
    // MARK: - User Settings Sync
    
    /// Pull settings from Supabase and write into @AppStorage (UserDefaults)
    func pullUserSettings() async throws {
        guard let settings = try await SupabaseManager.shared.fetchUserSettings() else {
            #if DEBUG
            print("[SyncManager] No user settings on server yet")
            #endif
            return
        }
        
        let store = UserDefaults.standard
        
        if let theme = settings.preferredTheme {
            store.set(theme, forKey: "appTheme")
        }
        if let unit = settings.distanceUnit {
            store.set(unit, forKey: "distance_unit")
        }
        // Guard against 0.0 values — a radius of 0 meters is never valid and
        // indicates the cloud row was poisoned by a previous push bug.
        if let v = settings.nearYouRadiusMeters, v > 0 {
            store.set(v, forKey: "near_you_radius_meters")
        }
        if let v = settings.fartherAwayRadiusMeters, v > 0 {
            store.set(v, forKey: "farther_away_radius_meters")
        }
        if let v = settings.muchFartherAwayRadiusMeters, v > 0 {
            store.set(v, forKey: "much_farther_away_radius_meters")
        }
        if let v = settings.showSystemMap {
            store.set(v, forKey: "show_system_map")
        }
        if let v = settings.subwayLineOffsetMeters {
            store.set(v, forKey: "subway_line_offset_meters")
        }
        if let v = settings.hapticsEnabled {
            store.set(v, forKey: "haptics_enabled")
        }
        if let v = settings.autoRefreshEnabled {
            store.set(v, forKey: "auto_refresh_enabled")
        }
        if let v = settings.dragToSearch {
            store.set(v, forKey: "drag_to_search")
        }
        // NOTE: dev_use_localhost and dev_custom_ip are intentionally NOT
        // pulled from cloud. These are device-specific networking flags —
        // a physical device on WiFi can't use another device's local IP.
        // Syncing them caused the app to flip between prod/dev URLs mid-session.
        
        #if DEBUG
        print("[SyncManager] Pulled user settings from cloud")
        #endif
    }
    
    /// Push current @AppStorage values to Supabase
    func pushUserSettings() async {
        let userId: UUID? =
            SupabaseManager.shared.currentUser?.id
            ?? defaults.string(forKey: "supabase_user_id").flatMap(UUID.init(uuidString:))

        guard let userId else {
            return
        }
        
        let store = UserDefaults.standard
        
        // Dev networking flags are device-specific and never synced.
        // Always push false/empty so the cloud row stays clean.
        let devUseLocalhostValue = false
        let devCustomIpValue = ""
        
        // Use AppSettings computed properties — they fall back to settings.json
        // defaults when the key hasn't been explicitly set in UserDefaults.
        // Raw store.double(forKey:) returns 0.0 for absent keys, which would
        // poison the cloud row and propagate 0-meter radii to all devices.
        let settings = CloudUserSettings(
            userId: userId,
            preferredTheme: store.string(forKey: "appTheme") ?? "system",
            distanceUnit: store.string(forKey: "distance_unit") ?? "mi",
            nearYouRadiusMeters: AppSettings.shared.nearYouRadiusMeters,
            fartherAwayRadiusMeters: AppSettings.shared.fartherAwayRadiusMeters,
            muchFartherAwayRadiusMeters: AppSettings.shared.muchFartherAwayRadiusMeters,
            showSystemMap: store.object(forKey: "show_system_map") as? Bool ?? true,
            subwayLineOffsetMeters: AppSettings.shared.subwayLineOffsetMeters,
            hapticsEnabled: store.object(forKey: "haptics_enabled") as? Bool ?? true,
            autoRefreshEnabled: store.object(forKey: "auto_refresh_enabled") as? Bool ?? true,
            notificationsEnabled: true,
            dragToSearch: store.object(forKey: "drag_to_search") as? Bool ?? false,
            devUseLocalhost: devUseLocalhostValue,
            devCustomIp: devCustomIpValue
        )
        
        do {
            try await SupabaseManager.shared.saveUserSettings(settings)
            #if DEBUG
            print("[SyncManager] Pushed user settings to cloud")
            #endif
        } catch {
            #if DEBUG
            print("[SyncManager] Failed to push settings: \(error)")
            #endif
        }
    }
    
    // MARK: - Commute Patterns Sync
    
    /// Pull commute patterns from Supabase to enrich local SmartSuggester data.
    func pullCommutePatterns() async {
        do {
            let patterns = try await SupabaseManager.shared.fetchCommutePatterns()
            if !patterns.isEmpty {
                #if DEBUG
                print("[SyncManager] Pulled \(patterns.count) commute patterns from cloud")
                #endif
            }
            // Patterns are available for SmartSuggester cross-device use.
            // The local SwiftData store is the primary source and is updated
            // when the user starts a trip; cloud patterns supplement that
            // on fresh installs or new devices.
        } catch {
            #if DEBUG
            print("[SyncManager] Failed to pull commute patterns: \(error)")
            #endif
        }
    }
    
    /// Upload a commute pattern to Supabase for cross-device sync
    func syncCommutePattern(
        routeId: String,
        direction: String,
        startLatitude: Double,
        startLongitude: Double,
        destinationStationId: String,
        destinationName: String,
        timeOfDay: Int,
        dayOfWeek: Int,
        frequency: Int
    ) async {
        do {
            try await SupabaseManager.shared.syncCommutePattern(
                routeId: routeId,
                direction: direction,
                startLatitude: startLatitude,
                startLongitude: startLongitude,
                destinationStationId: destinationStationId,
                destinationName: destinationName,
                timeOfDay: timeOfDay,
                dayOfWeek: dayOfWeek,
                frequency: frequency
            )
            #if DEBUG
            print("[SyncManager] Synced commute pattern for \(routeId)")
            #endif
        } catch {
            #if DEBUG
            print("[SyncManager] Failed to sync commute pattern: \(error)")
            #endif
        }
    }
    
    // MARK: - Time Parsing
    
    /// Cached DateFormatters for time string parsing
    private static let inputTimeFormatters: [DateFormatter] = [
        makeTimeFormatter("HH:mm:ss"),
        makeTimeFormatter("HH:mm"),
        makeTimeFormatter("H:mm:ss"),
        makeTimeFormatter("H:mm")
    ]
    private static let outputTimeFormatter = makeTimeFormatter("HH:mm")
    
    private static func makeTimeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
    
    /// Parses a time string from various formats to "HH:mm"
    private func parseTimeString(_ timeString: String) -> String {
        for formatter in Self.inputTimeFormatters {
            if let date = formatter.date(from: timeString) {
                return Self.outputTimeFormatter.string(from: date)
            }
        }
        
        // Fallback
        if timeString.count >= 5 {
            return String(timeString.prefix(5))
        }
        return timeString
    }
    
    // MARK: - Sync Status
    
    /// Formatted string showing when last sync occurred
    var lastSyncDescription: String {
        guard let date = lastSyncDate else {
            return "Never synced"
        }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

// MARK: - Sync Errors

enum SyncError: Error, LocalizedError {
    case notAuthenticated
    case networkUnavailable
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in to sync data"
        case .networkUnavailable:
            return "No network connection"
        }
    }
}
