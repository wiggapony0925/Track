// Defines the navigation pages that can be displayed within the
// universal bottom sheet. This enum-based approach provides type-safe
// navigation throughout the app's single-sheet interface.

import SwiftUI

/// Represents the different pages that can be displayed in the universal bottom sheet.
/// Each case corresponds to a distinct view that can be navigated to within the sheet.
enum SheetPage: Equatable, Identifiable {
    /// Main dashboard showing nearby transit arrivals
    case dashboard
    
    /// Route detail view for a specific transit route
    case routeDetail(
        group: GroupedNearbyTransitResponse,
        directionIndex: Int,
        initialTab: RouteDetailSheet.RouteDetailTab? = nil
    )

    /// Stop-level information for a tapped bus stop or train station
    case stopDetail(selection: StopDetailSelection)
    
    /// User profile management
    case profileSettings
    
    /// Full-page service alerts view
    case serviceAlerts
    
    /// Widget schedule management
    case widgetSchedules

    /// Saved address management
    case savedAddresses

    /// Manage and remove saved favorites
    case manageFavorites

#if DEBUG
    /// Developer tools and local backend controls (debug builds only)
    case developerSettings
#endif
    
    /// Schedule editor for a specific widget
    case scheduleEditor(schedule: WidgetSchedule?)
    
    // MARK: - Identifiable
    
    var id: String {
        switch self {
        case .dashboard:
            return "dashboard"
        case .routeDetail(let group, _, _):
            return "routeDetail-\(group.routeId)"
        case .stopDetail(let selection):
            return "stopDetail-\(selection.id)"
        case .profileSettings:
            return "profileSettings"
        case .serviceAlerts:
            return "serviceAlerts"
        case .widgetSchedules:
            return "widgetSchedules"
        case .savedAddresses:
            return "savedAddresses"
        case .manageFavorites:
            return "manageFavorites"
#if DEBUG
        case .developerSettings:
            return "developerSettings"
#endif
        case .scheduleEditor(let schedule):
            return "scheduleEditor-\(schedule?.id.uuidString ?? "new")"
        }
    }
    
    // MARK: - Equatable
    
    static func == (lhs: SheetPage, rhs: SheetPage) -> Bool {
        switch (lhs, rhs) {
        case (.dashboard, .dashboard):
            return true
        case (.routeDetail(let g1, let d1, let tab1), .routeDetail(let g2, let d2, let tab2)):
            return g1.routeId == g2.routeId && d1 == d2 && tab1 == tab2
        case (.stopDetail(let lhsSelection), .stopDetail(let rhsSelection)):
            return lhsSelection == rhsSelection
        case (.profileSettings, .profileSettings):
            return true
        case (.serviceAlerts, .serviceAlerts):
            return true
        case (.widgetSchedules, .widgetSchedules):
            return true
        case (.savedAddresses, .savedAddresses):
            return true
        case (.manageFavorites, .manageFavorites):
            return true
#if DEBUG
        case (.developerSettings, .developerSettings):
            return true
#endif
        case (.scheduleEditor(let s1), .scheduleEditor(let s2)):
            return s1?.id == s2?.id
        default:
            return false
        }
    }
}
