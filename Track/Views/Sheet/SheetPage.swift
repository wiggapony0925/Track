//
//  SheetPage.swift
//  Track
//
//  Defines the navigation pages that can be displayed within the
//  universal bottom sheet. This enum-based approach provides type-safe
//  navigation throughout the app's single-sheet interface.
//

import SwiftUI

/// Represents the different pages that can be displayed in the universal bottom sheet.
/// Each case corresponds to a distinct view that can be navigated to within the sheet.
enum SheetPage: Equatable, Identifiable {
    /// Main dashboard showing nearby transit arrivals
    case dashboard
    
    /// Route detail view for a specific transit route
    case routeDetail(group: GroupedNearbyTransitResponse, directionIndex: Int)
    
    /// Settings and preferences
    case settings
    
    /// Full-page service alerts view
    case serviceAlerts
    
    /// Widget schedule management
    case widgetSchedules
    
    /// Schedule editor for a specific widget
    case scheduleEditor(schedule: WidgetSchedule?)
    
    // MARK: - Identifiable
    
    var id: String {
        switch self {
        case .dashboard:
            return "dashboard"
        case .routeDetail(let group, _):
            return "routeDetail-\(group.routeId)"
        case .settings:
            return "settings"
        case .serviceAlerts:
            return "serviceAlerts"
        case .widgetSchedules:
            return "widgetSchedules"
        case .scheduleEditor(let schedule):
            return "scheduleEditor-\(schedule?.id.uuidString ?? "new")"
        }
    }
    
    // MARK: - Equatable
    
    static func == (lhs: SheetPage, rhs: SheetPage) -> Bool {
        switch (lhs, rhs) {
        case (.dashboard, .dashboard):
            return true
        case (.routeDetail(let g1, let d1), .routeDetail(let g2, let d2)):
            return g1.routeId == g2.routeId && d1 == d2
        case (.settings, .settings):
            return true
        case (.serviceAlerts, .serviceAlerts):
            return true
        case (.widgetSchedules, .widgetSchedules):
            return true
        case (.scheduleEditor(let s1), .scheduleEditor(let s2)):
            return s1?.id == s2?.id
        default:
            return false
        }
    }
}
