//
//  TrackWidgetBundle.swift
//  TrackWidgets
//
//  Entry point for the Widget Extension.
//  Registers active widgets: Single Route Tracking and Live Near Me (scheduled).
//

import SwiftUI
import WidgetKit

@main
struct TrackWidgetBundle: WidgetBundle {
    var body: some Widget {
        SingleRouteWidget()
        LiveNearMeWidget()
        TrackWidget()
        TrackWidgetLiveActivity()
    }
}
