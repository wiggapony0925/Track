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
//
//  Future:
//  - Commute patterns (smart suggestions)
//  - Favorites (when feature is added)
//

import Foundation
import Combine

/// Manages sync between local storage and Supabase cloud
@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    
    private let defaults = UserDefaults(suiteName: kAppGroupIdentifier) ?? .standard
    private let lastSyncKey = "last_sync_date"
    
    private init() {
        lastSyncDate = defaults.object(forKey: lastSyncKey) as? Date
    }
    
    // MARK: - Full Sync
    
    /// Performs a full sync of all user data
    func performFullSync() async {
        guard SupabaseManager.shared.isAuthenticated else {
            print("[SyncManager] Skipping sync - not authenticated")
            return
        }
        
        isSyncing = true
        syncError = nil
        
        do {
            // Sync schedules (download from cloud)
            try await syncSchedules()
            
            // Update last sync date
            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: lastSyncKey)
            
            print("[SyncManager] Sync completed successfully")
            
        } catch {
            syncError = error.localizedDescription
            print("[SyncManager] Sync error: \(error)")
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
            print("[SyncManager] Synced \(localSchedules.count) schedules from cloud")
        }
    }
    
    /// Uploads a schedule to Supabase (call when user creates/edits a schedule)
    func uploadSchedule(_ schedule: WidgetSchedule) async {
        guard let userIdString = defaults.string(forKey: "supabase_user_id"),
              let userId = UUID(uuidString: userIdString) else {
            print("[SyncManager] Cannot upload schedule - not authenticated")
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
            print("[SyncManager] Uploaded schedule \(schedule.id)")
        } catch {
            print("[SyncManager] Failed to upload schedule: \(error)")
        }
    }
    
    /// Deletes a schedule from Supabase
    func deleteSchedule(_ scheduleId: UUID) async {
        do {
            try await SupabaseManager.shared.deleteSchedule(id: scheduleId)
            print("[SyncManager] Deleted schedule \(scheduleId)")
        } catch {
            print("[SyncManager] Failed to delete schedule: \(error)")
        }
    }
    
    // MARK: - Time Parsing
    
    /// Parses a time string from various formats to "HH:mm"
    private func parseTimeString(_ timeString: String) -> String {
        let inputFormatters: [DateFormatter] = [
            createTimeFormatter("HH:mm:ss"),
            createTimeFormatter("HH:mm"),
            createTimeFormatter("H:mm:ss"),
            createTimeFormatter("H:mm")
        ]
        
        let outputFormatter = createTimeFormatter("HH:mm")
        
        for formatter in inputFormatters {
            if let date = formatter.date(from: timeString) {
                return outputFormatter.string(from: date)
            }
        }
        
        // Fallback
        if timeString.count >= 5 {
            return String(timeString.prefix(5))
        }
        return timeString
    }
    
    private func createTimeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
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
