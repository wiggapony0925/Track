//
//  SyncManager.swift
//  Track
//
//  Manages synchronization between local SwiftData storage and
//  Supabase cloud storage. Implements an offline-first approach
//  where data is always available locally and synced when online.
//

import Foundation
import SwiftData

/// Manages sync between local SwiftData and Supabase cloud
@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var syncError: String?
    
    private let defaults = UserDefaults(suiteName: "group.com.track.shared") ?? .standard
    private let lastSyncKey = "last_sync_date"
    
    private init() {
        lastSyncDate = defaults.object(forKey: lastSyncKey) as? Date
    }
    
    // MARK: - Full Sync
    
    /// Performs a full sync of all user data
    func performFullSync() async {
        guard SupabaseManager.shared.isAuthenticated else { return }
        
        isSyncing = true
        syncError = nil
        
        do {
            // Sync favorites
            try await syncFavorites()
            
            // Sync schedules
            try await syncSchedules()
            
            // Update last sync date
            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: lastSyncKey)
            
        } catch {
            syncError = error.localizedDescription
            print("Sync error: \(error)")
        }
        
        isSyncing = false
    }
    
    // MARK: - Favorites Sync
    
    /// Syncs favorites from Supabase to local storage
    func syncFavorites() async throws {
        let cloudFavorites = try await SupabaseManager.shared.fetchFavorites()
        
        // Store in UserDefaults for widget access
        let favoritesData = cloudFavorites.map { fav -> [String: Any] in
            var dict: [String: Any] = [
                "route_id": fav.routeId,
                "route_display_name": fav.routeDisplayName,
                "stop_id": fav.stopId,
                "stop_name": fav.stopName,
                "mode": fav.mode
            ]
            if let direction = fav.direction { dict["direction"] = direction }
            if let destination = fav.destination { dict["destination"] = destination }
            if let lat = fav.stopLat { dict["stop_lat"] = lat }
            if let lon = fav.stopLon { dict["stop_lon"] = lon }
            return dict
        }
        
        defaults.set(favoritesData, forKey: "synced_favorites")
    }
    
    /// Uploads a new favorite to Supabase
    func uploadFavorite(
        routeId: String,
        displayName: String,
        stopId: String,
        stopName: String,
        direction: String?,
        destination: String?,
        mode: String,
        latitude: Double?,
        longitude: Double?
    ) async throws {
        guard let userIdString = defaults.string(forKey: "supabase_user_id"),
              let userId = UUID(uuidString: userIdString) else {
            throw SyncError.notAuthenticated
        }
        
        let favorite = CloudFavorite(
            userId: userId,
            routeId: routeId,
            routeDisplayName: displayName,
            stopId: stopId,
            stopName: stopName,
            direction: direction,
            destination: destination,
            mode: mode,
            stopLat: latitude,
            stopLon: longitude
        )
        
        try await SupabaseManager.shared.addFavorite(favorite)
    }
    
    // MARK: - Schedules Sync
    
    /// Syncs schedules from Supabase to local WidgetSchedule storage
    func syncSchedules() async throws {
        let cloudSchedules = try await SupabaseManager.shared.fetchSchedules()
        
        // Convert to local WidgetSchedule format
        let localSchedules: [WidgetSchedule] = cloudSchedules.compactMap { cloud in
            guard let id = cloud.id else { return nil }
            
            // Convert time string "HH:mm:ss" to "HH:mm" using DateFormatter
            let startTime = parseTimeString(cloud.startTime)
            
            return WidgetSchedule(
                id: id,
                days: Set(cloud.daysOfWeek),
                startTime: startTime,
                duration: cloud.durationMinutes ?? 15,
                enabled: cloud.isEnabled ?? true
            )
        }
        
        // Save to local storage
        WidgetSchedule.saveAll(localSchedules)
    }
    
    /// Parses a time string from various formats to "HH:mm"
    /// Supports: "HH:mm:ss", "HH:mm", "H:mm", etc.
    private func parseTimeString(_ timeString: String) -> String {
        // Try parsing with DateFormatter for robust handling
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
        
        // Fallback: return first 5 characters if parsing fails
        // but log a warning
        print("[SyncManager] Warning: Could not parse time string '\(timeString)', using fallback")
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
    
    /// Uploads a schedule to Supabase
    func uploadSchedule(_ schedule: WidgetSchedule) async throws {
        guard let userIdString = defaults.string(forKey: "supabase_user_id"),
              let userId = UUID(uuidString: userIdString) else {
            throw SyncError.notAuthenticated
        }
        
        // Convert startTime "HH:mm" to "HH:mm:00"
        let startTime = schedule.startTime + ":00"
        
        let cloudSchedule = CloudSchedule(
            id: schedule.id,
            userId: userId,
            daysOfWeek: Array(schedule.days).sorted(),
            startTime: startTime,
            durationMinutes: schedule.duration,
            isEnabled: schedule.enabled
        )
        
        try await SupabaseManager.shared.upsertSchedule(cloudSchedule)
    }
    
    /// Deletes a schedule from Supabase
    func deleteSchedule(_ scheduleId: UUID) async throws {
        try await SupabaseManager.shared.deleteSchedule(id: scheduleId)
    }
    
    // MARK: - Local Favorites Access
    
    /// Returns locally synced favorites
    func getLocalFavorites() -> [[String: Any]] {
        return defaults.array(forKey: "synced_favorites") as? [[String: Any]] ?? []
    }
}

// MARK: - Sync Errors

enum SyncError: Error, LocalizedError {
    case notAuthenticated
    case networkUnavailable
    case conflictResolutionFailed
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in to sync data"
        case .networkUnavailable:
            return "No network connection"
        case .conflictResolutionFailed:
            return "Failed to resolve data conflict"
        }
    }
}
