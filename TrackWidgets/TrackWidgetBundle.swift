// Entry point for the Widget Extension.
// Registers active widgets: Single Route Tracking and Live Near Me (scheduled).

import SwiftUI
import WidgetKit

@main
struct TrackWidgetBundle: WidgetBundle {
    var body: some Widget {
        TripWidget()
        SingleRouteWidget()
        LiveNearMeWidget()
        TrackWidget()
        TrackWidgetLiveActivity()
    }
}
